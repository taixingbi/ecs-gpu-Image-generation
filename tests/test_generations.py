import os
from unittest.mock import MagicMock

os.environ["API_KEY"] = "test-key"
os.environ["OUTPUT_BUCKET"] = "test-bucket"

from fastapi.testclient import TestClient
from PIL import Image

import app.main as main_module
from app import inference


def _fake_image() -> Image.Image:
    return Image.new("RGB", (512, 512), color=(10, 20, 30))


def test_generate_requires_api_key(monkeypatch):
    monkeypatch.setattr(inference, "load_pipeline", lambda: None)
    monkeypatch.setattr(inference, "is_ready", lambda: True)
    with TestClient(main_module.app) as client:
        resp = client.post(
            "/v1/images/generations",
            json={"prompt": "a cat"},
        )
        assert resp.status_code == 401


def test_generate_success(monkeypatch):
    monkeypatch.setattr(inference, "load_pipeline", lambda: None)
    monkeypatch.setattr(inference, "is_ready", lambda: True)
    monkeypatch.setattr(inference, "get_model_id", lambda: "stabilityai/sdxl-turbo")
    monkeypatch.setattr(
        inference,
        "generate_image",
        lambda *args, **kwargs: _fake_image(),
    )
    monkeypatch.setattr(
        main_module,
        "upload_png",
        lambda image, request_id: f"https://example.com/{request_id}.png",
    )

    with TestClient(main_module.app) as client:
        resp = client.post(
            "/v1/images/generations",
            json={"prompt": "A futuristic GPU data center at night", "seed": 42},
            headers={"X-API-Key": "test-key"},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["model"] == "stabilityai/sdxl-turbo"
        assert "request_id" in body
        assert body["image_url"].startswith("https://example.com/")
        assert body["latency_ms"] >= 0


def test_generate_busy_returns_429(monkeypatch):
    monkeypatch.setattr(inference, "load_pipeline", lambda: None)
    monkeypatch.setattr(inference, "is_ready", lambda: True)

    # Mark semaphore as held without awaiting acquire in sync test.
    main_module.generation_semaphore = MagicMock()
    main_module.generation_semaphore.locked.return_value = True

    with TestClient(main_module.app) as client:
        resp = client.post(
            "/v1/images/generations",
            json={"prompt": "busy test"},
            headers={"X-API-Key": "test-key"},
        )
        assert resp.status_code == 429
        assert resp.json()["detail"] == "GPU is busy"
