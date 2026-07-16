resource "aws_cloudwatch_log_group" "api" {
  name              = local.log_group
  retention_in_days = 14

  tags = {
    Name = local.log_group
  }
}

resource "aws_cloudwatch_log_metric_filter" "error_count" {
  name           = "${local.service_name}-errors"
  log_group_name = aws_cloudwatch_log_group.api.name
  pattern        = "{ $.status = \"error\" || $.status = \"cuda_oom\" || $.status = \"upload_error\" }"

  metric_transformation {
    name      = "ErrorCount"
    namespace = "ecs-gpu-diffusers"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "cuda_oom" {
  name           = "${local.service_name}-cuda-oom"
  log_group_name = aws_cloudwatch_log_group.api.name
  pattern        = "{ $.status = \"cuda_oom\" }"

  metric_transformation {
    name      = "CudaOomCount"
    namespace = "ecs-gpu-diffusers"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${local.service_name}-error-rate"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ErrorCount"
  namespace           = "ecs-gpu-diffusers"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_description   = "SDXL Turbo API error count >= 5 in 5 minutes"
}

resource "aws_cloudwatch_metric_alarm" "cuda_oom" {
  alarm_name          = "${local.service_name}-cuda-oom"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CudaOomCount"
  namespace           = "ecs-gpu-diffusers"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "CUDA OOM detected"
}
