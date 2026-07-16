output "alb_dns_name" {
  description = "Public ALB DNS name"
  value       = aws_lb.api.dns_name
}

output "alb_url" {
  description = "Base URL for the API"
  value       = "http://${aws_lb.api.dns_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "output_bucket" {
  description = "S3 output bucket name"
  value       = aws_s3_bucket.output.id
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.api.name
}

output "api_key" {
  description = "API key for X-API-Key header"
  value       = local.api_key
  sensitive   = true
}

output "log_group" {
  description = "CloudWatch log group"
  value       = aws_cloudwatch_log_group.api.name
}
