variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.80.0.0/16"
}

variable "gpu_instance_type" {
  description = "EC2 GPU instance type for ECS capacity"
  type        = string
  default     = "g4dn.xlarge"
}

variable "image_tag" {
  description = "ECR image tag for the initial task definition"
  type        = string
  default     = "latest"
}

variable "api_key" {
  description = "Static API key for X-API-Key header. Leave empty to auto-generate."
  type        = string
  default     = ""
  sensitive   = true
}
