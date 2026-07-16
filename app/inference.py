import logging
import os
import time
from typing import Any, Optional

logger = logging.getLogger(__name__)

MODEL_ID = os.getenv("MODEL_ID", "stabilityai/sdxl-turbo")
# When set and present on disk, weights are loaded from this local directory
# (staged from S3 at instance boot) instead of downloading from Hugging Face.
MODEL_DIR = os.getenv("MODEL_DIR", "")

_pipeline = None
_model_ready = False
_model_load_seconds: Optional[float] = None
_load_error: Optional[str] = None


def is_ready() -> bool:
    return _model_ready and _pipeline is not None


def get_model_id() -> str:
    return MODEL_ID


def get_load_seconds() -> Optional[float]:
    return _model_load_seconds


def get_load_error() -> Optional[str]:
    return _load_error


def cuda_available() -> bool:
    try:
        import torch

        return torch.cuda.is_available()
    except ImportError:
        return False


def load_pipeline() -> None:
    """Download and load the Diffusers pipeline onto CUDA."""
    global _pipeline, _model_ready, _model_load_seconds, _load_error

    if _model_ready and _pipeline is not None:
        return

    start = time.perf_counter()
    try:
        import torch
        from diffusers import AutoPipelineForText2Image

        if not torch.cuda.is_available():
            raise RuntimeError("CUDA is not available")

        use_local = bool(MODEL_DIR) and os.path.isdir(MODEL_DIR)
        if use_local:
            # Avoid any network calls to the Hub when loading local weights.
            os.environ.setdefault("HF_HUB_OFFLINE", "1")
            os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
            model_source = MODEL_DIR
            logger.info("Loading model from local dir %s (fp16) onto CUDA", MODEL_DIR)
        else:
            model_source = MODEL_ID
            logger.info("Loading model %s (fp16) from Hugging Face onto CUDA", MODEL_ID)

        pipeline = AutoPipelineForText2Image.from_pretrained(
            model_source,
            torch_dtype=torch.float16,
            variant="fp16",
        )
        pipeline = pipeline.to("cuda")
        pipeline.set_progress_bar_config(disable=True)

        # Touch GPU memory so readiness reflects a successful allocation.
        _ = torch.zeros(1, device="cuda", dtype=torch.float16)

        _pipeline = pipeline
        _model_ready = True
        _load_error = None
        _model_load_seconds = time.perf_counter() - start
        logger.info(
            "model_loaded model=%s load_seconds=%.2f",
            MODEL_ID,
            _model_load_seconds,
        )
    except Exception as exc:  # noqa: BLE001 — surface any load failure as not-ready
        _pipeline = None
        _model_ready = False
        _load_error = str(exc)
        _model_load_seconds = time.perf_counter() - start
        logger.exception("Model load failed: %s", exc)
        raise


def generate_image(
    prompt: str,
    *,
    width: int = 512,
    height: int = 512,
    steps: int = 1,
    seed: Optional[int] = None,
) -> Any:
    if not is_ready() or _pipeline is None:
        raise RuntimeError("Model is not ready")

    import torch

    generator = None
    if seed is not None:
        generator = torch.Generator(device="cuda").manual_seed(seed)

    result = _pipeline(
        prompt=prompt,
        num_inference_steps=steps,
        guidance_scale=0.0,
        width=width,
        height=height,
        generator=generator,
    )
    return result.images[0]
