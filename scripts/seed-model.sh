#!/usr/bin/env bash
# Download the SDXL-Turbo weights from Hugging Face and stage them in S3 so GPU
# instances can load the model locally instead of pulling from the Hub.
#
# Run this ONCE (from a machine with internet + AWS credentials) before the ECS
# task starts, or any time you change MODEL_ID.
#
# Usage:
#   ./scripts/seed-model.sh                      # bucket/model from terraform output + defaults
#   ./scripts/seed-model.sh <bucket>             # explicit bucket
#   MODEL_ID=stabilityai/sdxl-turbo ./scripts/seed-model.sh <bucket>
#
# Requires: aws CLI, python3 (with huggingface_hub; auto-installed if missing).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
AWS_REGION="${AWS_REGION:-us-east-1}"
MODEL_ID="${MODEL_ID:-stabilityai/sdxl-turbo}"
MODEL_PREFIX="${MODEL_PREFIX:-models/sdxl-turbo}"
LOCAL_DIR="${LOCAL_DIR:-${ROOT_DIR}/.model-cache/sdxl-turbo}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need aws
need python3

BUCKET="${1:-}"
if [[ -z "${BUCKET}" ]]; then
  if [[ -d "${TF_DIR}/.terraform" ]]; then
    BUCKET="$(terraform -chdir="${TF_DIR}" output -raw output_bucket 2>/dev/null || true)"
  fi
fi
if [[ -z "${BUCKET}" ]]; then
  echo "Could not determine target bucket. Pass it explicitly:" >&2
  echo "  ./scripts/seed-model.sh <bucket>" >&2
  exit 1
fi

DEST="s3://${BUCKET}/${MODEL_PREFIX}"

echo "==> Model:  ${MODEL_ID}"
echo "==> Local:  ${LOCAL_DIR}"
echo "==> Dest:   ${DEST}"
echo "==> Region: ${AWS_REGION}"

if ! python3 -c "import huggingface_hub" >/dev/null 2>&1; then
  echo "==> Installing huggingface_hub"
  python3 -m pip install --quiet --upgrade huggingface_hub
fi

echo "==> Downloading snapshot from Hugging Face"
python3 - "$MODEL_ID" "$LOCAL_DIR" <<'PY'
import sys
from huggingface_hub import snapshot_download

repo_id, local_dir = sys.argv[1], sys.argv[2]
path = snapshot_download(repo_id=repo_id, local_dir=local_dir)
print(f"downloaded to {path}")
PY

echo "==> Syncing to ${DEST}"
aws s3 sync "${LOCAL_DIR}/" "${DEST}/" \
  --region "${AWS_REGION}" \
  --only-show-errors \
  --exclude ".cache/*" \
  --exclude "*.lock"

echo
echo "Done. Model staged at ${DEST}"
echo "New GPU instances will sync it to /opt/models/sdxl-turbo at boot."
echo "If an instance is already running, trigger an ASG instance refresh to pick it up."
