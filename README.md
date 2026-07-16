# ecs-gpu-diffusers

Independent ECS-on-EC2 GPU MVP for **stabilityai/sdxl-turbo**.

Docker image → ECR → ECS (g4dn.xlarge) → Diffusers → REST API → S3 → CloudWatch.

Not connected to HuntAI, Kubernetes, Bedrock, or existing gateways.

## Architecture

```
Client
  │  POST /v1/images/generations  (X-API-Key)
  ▼
Public ALB :80
  ▼
ECS service sdxl-turbo-api  (1 task, 1× GPU)
  ├── FastAPI + PyTorch + Diffusers
  └── /opt/models host cache → /models
        │
        ▼
     S3 private bucket (presigned URL)
```

## AWS resources

| Resource | Name |
|----------|------|
| ECS cluster | `ecs-gpu-diffusers-dev` |
| ECS service / task | `sdxl-turbo-api` |
| ECR | `ecs-gpu-diffusers` |
| S3 | `ecs-gpu-diffusers-output-<account-id>` |
| Log group | `/ecs/sdxl-turbo-api` |
| Instance | `g4dn.xlarge` (ASG min/desired/max = 1) |

## API

| Method | Path | Auth | Notes |
|--------|------|------|-------|
| `GET` | `/health` | none | Process up |
| `GET` | `/ready` | none | CUDA + model loaded (503 until ready) |
| `POST` | `/v1/images/generations` | `X-API-Key` | Generate + upload |

Request:

```json
{
  "prompt": "A futuristic GPU data center at night",
  "width": 512,
  "height": 512,
  "steps": 1,
  "seed": 42
}
```

Response:

```json
{
  "request_id": "f1386ac4",
  "model": "stabilityai/sdxl-turbo",
  "latency_ms": 1350,
  "image_url": "https://presigned-s3-url"
}
```

Defaults: `num_inference_steps=1`, `guidance_scale=0.0`, `512×512`. Concurrent generation returns **429** `GPU is busy`.

## Local (Phase 1 — GPU machine)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export API_KEY=dev-key
export OUTPUT_BUCKET=  # leave empty only if you mock storage; ECS requires a bucket
pytest -q

docker build -t ecs-gpu-diffusers:local .
docker run --gpus all -p 8000:8000 \
  -e API_KEY=dev-key \
  -e OUTPUT_BUCKET=your-bucket \
  -e AWS_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID=... \
  -e AWS_SECRET_ACCESS_KEY=... \
  -v /opt/models:/models \
  ecs-gpu-diffusers:local
```

Wait for `/ready` (model download can take several minutes), then:

```bash
curl -s http://localhost:8000/health
curl -s http://localhost:8000/ready
curl -s -X POST http://localhost:8000/v1/images/generations \
  -H "Content-Type: application/json" \
  -H "X-API-Key: dev-key" \
  -d '{"prompt":"A futuristic GPU data center at night","seed":42}'
```

## Bootstrap infrastructure (Terraform)

Requires AWS credentials with VPC/ECS/ECR/IAM/S3 permissions and a GPU quota for `g4dn.xlarge` in `us-east-1`.

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
terraform output alb_url
terraform output -raw api_key
```

First apply creates ECR/cluster/ASG/ALB/service. The task may fail to pull until the first image exists — that is expected.

## CD (push to `main`)

GitHub Actions [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml):

1. `pytest`
2. Build & push image to ECR (`:sha` + `:latest`)
3. Register new task definition revision
4. Update ECS service and wait for stability

**Required repo secrets** (already configured):

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

IAM for those credentials needs at least: ECR push/pull, `ecs:Describe*`, `ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `iam:PassRole` on the ECS task/execution roles.

After Terraform succeeds, push to `main` to deploy the first image:

```bash
git add -A && git commit -m "Initial ecs-gpu-diffusers MVP"
git push origin main
```

Then:

```bash
ALB=$(cd infra/terraform && terraform output -raw alb_url)
KEY=$(cd infra/terraform && terraform output -raw api_key)

# Allow ~10 minutes for instance + model load
curl -s "$ALB/health"
curl -s "$ALB/ready"
curl -s -X POST "$ALB/v1/images/generations" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $KEY" \
  -d '{"prompt":"A futuristic GPU data center at night","seed":42}'
```

## MVP limits

- 1 GPU instance, 1 ECS task, 1 model
- 1 request at a time (semaphore)
- 512×512 only, 1–4 steps
- No queue, no autoscaling, no Fargate, no HuntAI

## Validation checklist

- [ ] Task restart reuses `/opt/models` cache
- [ ] EC2 replacement re-downloads model
- [ ] New task definition via `main` push rolls successfully
- [ ] Second concurrent POST returns 429
- [ ] Invalid width/steps rejected (422)
- [ ] Structured JSON logs in `/ecs/sdxl-turbo-api`
- [ ] CloudWatch alarms for errors / CUDA OOM
