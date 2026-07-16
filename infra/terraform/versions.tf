terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ecs-gpu-diffusers"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix   = "ecs-gpu-diffusers"
  account_id    = data.aws_caller_identity.current.account_id
  output_bucket = "${local.name_prefix}-output-${local.account_id}"
  ecr_repo_name = "ecs-gpu-diffusers"
  cluster_name  = "ecs-gpu-diffusers-dev"
  service_name  = "sdxl-turbo-api"
  task_family   = "sdxl-turbo-api"
  log_group     = "/ecs/sdxl-turbo-api"

  # Model weights are staged in the output bucket under this prefix (see
  # scripts/seed-model.sh). GPU instances sync it to the host at boot and the
  # container loads it from a local directory instead of downloading from HF.
  model_prefix        = "models/sdxl-turbo"
  model_s3_uri        = "s3://${local.output_bucket}/${local.model_prefix}"
  model_host_dir      = "/opt/models/sdxl-turbo"
  model_container_dir = "/models/sdxl-turbo"
}
