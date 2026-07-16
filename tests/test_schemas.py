from app.schemas import GenerationRequest


def test_generation_request_defaults():
    req = GenerationRequest(prompt="a cat")
    assert req.width == 512
    assert req.height == 512
    assert req.steps == 1
    assert req.seed is None


def test_generation_request_rejects_non_512():
    import pytest
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        GenerationRequest(prompt="x", width=1024)

    with pytest.raises(ValidationError):
        GenerationRequest(prompt="x", steps=8)
