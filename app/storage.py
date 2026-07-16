import io
import logging
import os
from typing import Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from PIL import Image

logger = logging.getLogger(__name__)

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
OUTPUT_BUCKET = os.getenv("OUTPUT_BUCKET", "")
PRESIGN_EXPIRES_SECONDS = int(os.getenv("PRESIGN_EXPIRES_SECONDS", "3600"))


def _s3_client():
    return boto3.client("s3", region_name=AWS_REGION)


def upload_png(image: Image.Image, request_id: str, bucket: Optional[str] = None) -> str:
    """Upload a PNG to S3 and return a presigned GET URL."""
    target_bucket = bucket or OUTPUT_BUCKET
    if not target_bucket:
        raise RuntimeError("OUTPUT_BUCKET is not configured")

    key = f"generations/{request_id}.png"
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    buffer.seek(0)

    client = _s3_client()
    try:
        client.put_object(
            Bucket=target_bucket,
            Key=key,
            Body=buffer.getvalue(),
            ContentType="image/png",
        )
        url = client.generate_presigned_url(
            "get_object",
            Params={"Bucket": target_bucket, "Key": key},
            ExpiresIn=PRESIGN_EXPIRES_SECONDS,
        )
    except (BotoCoreError, ClientError) as exc:
        logger.exception("S3 upload failed for %s", key)
        raise RuntimeError(f"S3 upload failed: {exc}") from exc

    logger.info("s3_upload bucket=%s key=%s", target_bucket, key)
    return url
