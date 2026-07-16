import asyncio
import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse

from app import inference
from app.schemas import (
    GenerationRequest,
    GenerationResponse,
    HealthResponse,
    ReadyResponse,
)
from app.storage import upload_png

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

# Pure-JSON logger for CloudWatch metric filters (message body must be JSON).
_metrics_logger = logging.getLogger("app.metrics")
_metrics_logger.propagate = False
if not _metrics_logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(logging.Formatter("%(message)s"))
    _metrics_logger.addHandler(_handler)
    _metrics_logger.setLevel(logging.INFO)

API_KEY = os.getenv("API_KEY", "")
generation_semaphore = asyncio.Semaphore(1)

metrics = {
    "request_count": 0,
    "error_count": 0,
    "cuda_oom_count": 0,
}


@asynccontextmanager
async def lifespan(_app: FastAPI):
    logger.info("Starting model load in background")
    loop = asyncio.get_running_loop()
    try:
        await loop.run_in_executor(None, inference.load_pipeline)
        logger.info(
            "model_load_seconds=%.2f",
            inference.get_load_seconds() or 0.0,
        )
    except Exception:  # noqa: BLE001
        logger.exception("Startup model load failed; /ready will return 503")
    yield


app = FastAPI(title="sdxl-turbo-api", version="0.1.0", lifespan=lifespan)


async def require_api_key(x_api_key: Optional[str] = Header(default=None)) -> None:
    if not API_KEY:
        raise HTTPException(status_code=500, detail="API_KEY is not configured")
    if not x_api_key or x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing X-API-Key")


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse(status="ok")


@app.get("/ready", response_model=ReadyResponse)
async def ready():
    if not inference.is_ready() or not inference.cuda_available():
        return JSONResponse(
            status_code=503,
            content={
                "status": "not_ready",
                "model": inference.get_model_id(),
                "cuda": inference.cuda_available(),
                "error": inference.get_load_error(),
            },
        )
    return ReadyResponse(
        status="ready",
        model=inference.get_model_id(),
        cuda=True,
    )


@app.post(
    "/v1/images/generations",
    response_model=GenerationResponse,
    dependencies=[Depends(require_api_key)],
)
async def generate(body: GenerationRequest) -> GenerationResponse:
    if not inference.is_ready():
        raise HTTPException(status_code=503, detail="Model is not ready")

    request_id = uuid.uuid4().hex[:8]
    total_start = time.perf_counter()
    queue_ms = 0
    inference_ms = 0
    upload_ms = 0
    status = "success"

    metrics["request_count"] += 1

    if generation_semaphore.locked():
        metrics["error_count"] += 1
        _log_request(
            request_id=request_id,
            body=body,
            queue_ms=0,
            inference_ms=0,
            upload_ms=0,
            total_ms=int((time.perf_counter() - total_start) * 1000),
            status="busy",
        )
        raise HTTPException(status_code=429, detail="GPU is busy")

    queue_start = time.perf_counter()
    await generation_semaphore.acquire()
    queue_ms = int((time.perf_counter() - queue_start) * 1000)

    try:
        loop = asyncio.get_running_loop()
        infer_start = time.perf_counter()
        try:
            image = await loop.run_in_executor(
                None,
                lambda: inference.generate_image(
                    body.prompt,
                    width=body.width,
                    height=body.height,
                    steps=body.steps,
                    seed=body.seed,
                ),
            )
        except Exception as exc:  # noqa: BLE001
            inference_ms = int((time.perf_counter() - infer_start) * 1000)
            metrics["error_count"] += 1
            if _is_cuda_oom(exc):
                metrics["cuda_oom_count"] += 1
                status = "cuda_oom"
                _log_request(
                    request_id=request_id,
                    body=body,
                    queue_ms=queue_ms,
                    inference_ms=inference_ms,
                    upload_ms=0,
                    total_ms=int((time.perf_counter() - total_start) * 1000),
                    status=status,
                )
                raise HTTPException(status_code=500, detail="CUDA out of memory") from exc
            status = "error"
            logger.exception("Inference failed request_id=%s", request_id)
            _log_request(
                request_id=request_id,
                body=body,
                queue_ms=queue_ms,
                inference_ms=inference_ms,
                upload_ms=0,
                total_ms=int((time.perf_counter() - total_start) * 1000),
                status=status,
            )
            raise HTTPException(status_code=500, detail=str(exc)) from exc

        inference_ms = int((time.perf_counter() - infer_start) * 1000)

        upload_start = time.perf_counter()
        try:
            image_url = await loop.run_in_executor(
                None,
                lambda: upload_png(image, request_id),
            )
        except Exception as exc:  # noqa: BLE001
            upload_ms = int((time.perf_counter() - upload_start) * 1000)
            metrics["error_count"] += 1
            status = "upload_error"
            _log_request(
                request_id=request_id,
                body=body,
                queue_ms=queue_ms,
                inference_ms=inference_ms,
                upload_ms=upload_ms,
                total_ms=int((time.perf_counter() - total_start) * 1000),
                status=status,
            )
            raise HTTPException(status_code=500, detail=str(exc)) from exc

        upload_ms = int((time.perf_counter() - upload_start) * 1000)
        total_ms = int((time.perf_counter() - total_start) * 1000)
        _log_request(
            request_id=request_id,
            body=body,
            queue_ms=queue_ms,
            inference_ms=inference_ms,
            upload_ms=upload_ms,
            total_ms=total_ms,
            status=status,
        )
        return GenerationResponse(
            request_id=request_id,
            model=inference.get_model_id(),
            latency_ms=total_ms,
            image_url=image_url,
        )
    finally:
        generation_semaphore.release()


def _is_cuda_oom(exc: BaseException) -> bool:
    try:
        import torch

        return isinstance(exc, torch.cuda.OutOfMemoryError)
    except Exception:  # noqa: BLE001
        return False


def _log_request(
    *,
    request_id: str,
    body: GenerationRequest,
    queue_ms: int,
    inference_ms: int,
    upload_ms: int,
    total_ms: int,
    status: str,
) -> None:
    event = {
        "request_id": request_id,
        "model": inference.get_model_id(),
        "width": body.width,
        "height": body.height,
        "steps": body.steps,
        "queue_ms": queue_ms,
        "inference_ms": inference_ms,
        "upload_ms": upload_ms,
        "total_ms": total_ms,
        "status": status,
        "generation_latency_ms": inference_ms,
        "queue_latency_ms": queue_ms,
    }
    # Emit pure JSON so CloudWatch metric filters can use JSON path syntax.
    _metrics_logger.info("%s", json.dumps(event))
