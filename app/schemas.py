from typing import Optional

from pydantic import BaseModel, Field


class GenerationRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=2000)
    width: int = Field(default=512, ge=512, le=512)
    height: int = Field(default=512, ge=512, le=512)
    steps: int = Field(default=1, ge=1, le=4)
    seed: Optional[int] = Field(default=None, ge=0)


class GenerationResponse(BaseModel):
    request_id: str
    model: str
    latency_ms: int
    image_url: str


class HealthResponse(BaseModel):
    status: str


class ReadyResponse(BaseModel):
    status: str
    model: str
    cuda: bool
