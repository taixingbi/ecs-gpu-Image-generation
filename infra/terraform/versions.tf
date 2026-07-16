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
}
