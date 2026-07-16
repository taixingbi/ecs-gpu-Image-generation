import os

os.environ["API_KEY"] = "test-key"
os.environ["OUTPUT_BUCKET"] = "test-bucket"

from fastapi.testclient import TestClient

import app.main as main_module
from app import inference


def test_health_ok(monkeypatch):
    monkeypatch.setattr(inference, "load_pipeline", lambda: None)
    with TestClient(main_module.app) as client:
        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "ok"}


def test_ready_not_ready(monkeypatch):
    monkeypatch.setattr(inference, "load_pipeline", lambda: None)
    monkeypatch.setattr(inference, "is_ready", lambda: False)
    monkeypatch.setattr(inference, "cuda_available", lambda: False)
    with TestClient(main_module.app) as client:
        resp = client.get("/ready")
        assert resp.status_code == 503
        body = resp.json()
        assert body["status"] == "not_ready"


def test_ready_ok(monkeypatch):
    monkeypatch.setattr(inference, "load_pipeline", lambda: None)
    monkeypatch.setattr(inference, "is_ready", lambda: True)
    monkeypatch.setattr(inference, "cuda_available", lambda: True)
    monkeypatch.setattr(inference, "get_model_id", lambda: "stabilityai/sdxl-turbo")
    with TestClient(main_module.app) as client:
        resp = client.get("/ready")
        assert resp.status_code == 200
        assert resp.json() == {
            "status": "ready",
            "model": "stabilityai/sdxl-turbo",
            "cuda": True,
        }
