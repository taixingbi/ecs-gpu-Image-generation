#!/usr/bin/env bash
# Tear down all ecs-gpu-diffusers AWS resources created by Terraform.
#
# Usage:
#   ./scripts/destroy-all.sh           # interactive confirm
#   ./scripts/destroy-all.sh --yes     # no prompt
#   FORCE=1 ./scripts/destroy-all.sh   # same as --yes
#
# Requires: aws CLI, terraform, credentials for the target account/region.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
AWS_REGION="${AWS_REGION:-us-east-1}"
YES=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ "${FORCE:-0}" == "1" ]]; then
  YES=1
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need aws
need terraform

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

echo "==> Target region: ${AWS_REGION}"
echo "==> Terraform dir: ${TF_DIR}"

if [[ ! -d "${TF_DIR}" ]]; then
  echo "Terraform directory not found: ${TF_DIR}" >&2
  exit 1
fi

cd "${TF_DIR}"

if [[ ! -d .terraform ]]; then
  echo "==> terraform init"
  terraform init -input=false
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "==> AWS account: ${ACCOUNT_ID}"

CLUSTER="$(terraform output -raw ecs_cluster_name 2>/dev/null || true)"
SERVICE="$(terraform output -raw ecs_service_name 2>/dev/null || true)"
BUCKET="$(terraform output -raw output_bucket 2>/dev/null || true)"
ECR_URL="$(terraform output -raw ecr_repository_url 2>/dev/null || true)"

echo
echo "This will DESTROY:"
echo "  - Terraform stack in ${TF_DIR}"
echo "  - ECS cluster/service (scale to 0 first if present)"
echo "  - S3 bucket contents (then bucket via terraform)"
echo "  - ECR images (repo force_delete via terraform)"
echo "  - VPC, ALB, g4dn ASG, IAM, CloudWatch log group"
echo

if [[ "${YES}" != "1" ]]; then
  read -r -p "Type 'destroy' to continue: " CONFIRM
  if [[ "${CONFIRM}" != "destroy" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Scale service to zero so tasks drain before ASG/instance destroy.
if [[ -n "${CLUSTER}" && -n "${SERVICE}" ]]; then
  echo "==> Scaling ECS service ${SERVICE} to 0"
  aws ecs update-service \
    --cluster "${CLUSTER}" \
    --service "${SERVICE}" \
    --desired-count 0 \
    --region "${AWS_REGION}" \
    >/dev/null 2>&1 || echo "    (service already gone or unreachable; continuing)"

  echo "==> Waiting briefly for tasks to stop"
  sleep 15
fi

# Empty S3 so terraform destroy does not fail on non-empty bucket.
if [[ -n "${BUCKET}" ]]; then
  if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
    echo "==> Emptying s3://${BUCKET}"
    aws s3 rm "s3://${BUCKET}" --recursive --region "${AWS_REGION}" || true
  else
    echo "==> Bucket ${BUCKET} not found; skipping empty"
  fi
else
  # Fallback name if state/outputs are missing
  FALLBACK_BUCKET="ecs-gpu-diffusers-output-${ACCOUNT_ID}"
  if aws s3api head-bucket --bucket "${FALLBACK_BUCKET}" 2>/dev/null; then
    echo "==> Emptying fallback s3://${FALLBACK_BUCKET}"
    aws s3 rm "s3://${FALLBACK_BUCKET}" --recursive --region "${AWS_REGION}" || true
  fi
fi

# Best-effort: drain ECR images if repo exists (terraform also force_deletes).
if [[ -n "${ECR_URL}" ]]; then
  REPO_NAME="$(basename "${ECR_URL}")"
  echo "==> Deleting images in ECR ${REPO_NAME} (best effort)"
  IMAGES="$(aws ecr list-images --repository-name "${REPO_NAME}" --region "${AWS_REGION}" --query 'imageIds[*]' --output json 2>/dev/null || echo '[]')"
  if [[ "${IMAGES}" != "[]" && "${IMAGES}" != "" ]]; then
    aws ecr batch-delete-image \
      --repository-name "${REPO_NAME}" \
      --region "${AWS_REGION}" \
      --image-ids "${IMAGES}" \
      >/dev/null 2>&1 || true
  fi
fi

echo "==> terraform destroy"
terraform destroy -auto-approve -input=false

echo
echo "Done. All Terraform-managed ecs-gpu-diffusers resources should be gone."
echo "Note: local Docker images and GitHub Actions history are not removed."
