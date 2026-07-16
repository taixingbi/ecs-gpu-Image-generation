resource "aws_ecs_cluster" "main" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = local.cluster_name
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.gpu.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.gpu.name
    weight            = 1
    base              = 1
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = local.task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = "3072"
  memory                   = "12288"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = local.service_name
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true
      cpu       = 3072
      memory    = 12288
      resourceRequirements = [
        {
          type  = "GPU"
          value = "1"
        }
      ]
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "MODEL_ID", value = "stabilityai/sdxl-turbo" },
        { name = "HF_HOME", value = "/models/huggingface" },
        { name = "TORCH_HOME", value = "/models/torch" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "OUTPUT_BUCKET", value = aws_s3_bucket.output.id },
        { name = "API_KEY", value = local.api_key },
        { name = "PYTHONUNBUFFERED", value = "1" }
      ]
      mountPoints = [
        {
          sourceVolume  = "model-cache"
          containerPath = "/models"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 300
      }
    }
  ])

  volume {
    name = "model-cache"

    host_path = "/opt/models"
  }

  tags = {
    Name = local.task_family
  }
}

resource "aws_ecs_service" "api" {
  name                               = local.service_name
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = 1
  launch_type                        = null
  scheduling_strategy                = "REPLICA"
  health_check_grace_period_seconds  = 600
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = true

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.gpu.name
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = local.service_name
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.http,
    aws_ecs_cluster_capacity_providers.main,
  ]

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = {
    Name = local.service_name
  }
}
