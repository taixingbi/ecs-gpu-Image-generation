# ECS-optimized GPU AMI (Amazon Linux 2)
data "aws_ssm_parameter" "ecs_gpu_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended/image_id"
}

resource "aws_launch_template" "gpu" {
  name_prefix   = "${local.name_prefix}-gpu-"
  image_id      = data.aws_ssm_parameter.ecs_gpu_ami.value
  instance_type = var.gpu_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  vpc_security_group_ids = [aws_security_group.ecs_instances.id]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -eux
    mkdir -p /opt/models
    chmod 777 /opt/models

    # Pre-seed model weights from S3 so the container loads them locally instead
    # of downloading from Hugging Face. Non-fatal if the prefix is not populated
    # yet; the app falls back to a Hugging Face download in that case.
    if aws s3 ls "${local.model_s3_uri}/" --region ${var.aws_region} >/dev/null 2>&1; then
      mkdir -p ${local.model_host_dir}
      aws s3 sync "${local.model_s3_uri}/" ${local.model_host_dir}/ --region ${var.aws_region} --only-show-errors
      chmod -R 777 ${local.model_host_dir}
    fi

    echo "ECS_CLUSTER=${local.cluster_name}" >> /etc/ecs/ecs.config
    echo "ECS_ENABLE_GPU_SUPPORT=true" >> /etc/ecs/ecs.config
  EOF
  )

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name_prefix}-gpu"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "gpu" {
  name                = "${local.name_prefix}-gpu-asg"
  vpc_zone_identifier = aws_subnet.private[*].id
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1

  launch_template {
    id      = aws_launch_template.gpu.id
    version = "$Latest"
  }

  protect_from_scale_in = false

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-gpu"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# NOTE: ECS capacity provider names cannot start with "aws", "ecs", or "fargate",
# so this does not use local.name_prefix (which is "ecs-gpu-diffusers").
resource "aws_ecs_capacity_provider" "gpu" {
  name = "gpu-diffusers-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.gpu.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      # Fixed capacity MVP (ASG min=desired=max=1); do not let ECS scale the ASG.
      status = "DISABLED"
    }
  }
}
