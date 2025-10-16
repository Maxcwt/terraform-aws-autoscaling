provider "aws" {
  region = var.aws_region
}
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
module "discovery" {
  source              = "github.com/Lowess/terraform-aws-discovery"
  aws_region          = var.aws_region
  vpc_name            = var.vpc_name
  ec2_ami_names       = var.ec2_ami_names
  ec2_ami_owners      = var.ec2_ami_owners
  ec2_security_groups = var.ec2_security_groups
}

locals {
  vpc_id         = module.discovery.vpc_id
  public_subnets = module.discovery.public_subnets
  private_subnets= module.discovery.private_subnets
  ami_id         = "ami-072ca9069b5972cdd"
}

resource "aws_security_group" "alb" {
  name   = "${var.app_name}-alb"
  vpc_id = local.vpc_id
  tags   = { Name = "${var.app_name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_in" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_vpc_security_group_ingress_rule" "asg_from_alb_netdata" {
  security_group_id            = aws_security_group.asg.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 19999
  to_port                      = 19999
}


resource "aws_vpc_security_group_egress_rule" "alb_all_out" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "asg" {
  name   = "${var.app_name}"
  vpc_id = local.vpc_id
  tags   = { Name = var.app_name }
}

resource "aws_vpc_security_group_ingress_rule" "asg_from_alb" {
  security_group_id            = aws_security_group.asg.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}
resource "aws_vpc_security_group_ingress_rule" "alb_8080_in" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_ipv4         = "0.0.0.0/0"
}


resource "aws_vpc_security_group_egress_rule" "asg_all_out" {
  security_group_id = aws_security_group.asg.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}


resource "aws_lb" "public" {
  name               = "${var.app_name}-alb-public"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.public_subnets
  tags = { Tier = "public", Name = "${var.app_name}-alb-public" }
}

resource "aws_lb_target_group" "http" {
  name        = "${var.app_name}-http"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = local.vpc_id

  health_check {
    protocol = "HTTP"
    port     = "8080"                 # <— health check sur 8080
    path     = "/"                    # ou "/index.html" si tu préfères
    healthy_threshold   = 2
    unhealthy_threshold = 5
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }
}


resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}



resource "aws_launch_template" "lt" {
  name_prefix   = "${var.app_name}-lt-"
  image_id      = local.ami_id
  instance_type = "t3.micro"
  key_name      = var.key_name

  network_interfaces {
    security_groups = [aws_security_group.asg.id]
    delete_on_termination = true
  }

  user_data = null

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "${var.app_name}" }
  }
}

resource "aws_autoscaling_group" "asg" {
  name                      = "${var.app_name}-asg"
  max_size                  = 2
  min_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = local.private_subnets
  health_check_type         = "ELB"
  health_check_grace_period = 60
  default_instance_warmup = 60

  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  target_group_arns = [
    aws_lb_target_group.http.arn,
    aws_lb_target_group.netdata.arn,
  ]

  tag {
    key                 = "Name"
    value               = var.app_name
    propagate_at_launch = true
  }
}

# Scale OUT: +1 instance
resource "aws_autoscaling_policy" "cpu_scale_out" {
  name                   = "${var.app_name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 120
}

# Scale IN: -1 instance
resource "aws_autoscaling_policy" "cpu_scale_in" {
  name                   = "${var.app_name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.app_name}-cpu-high"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"

  dimensions = { AutoScalingGroupName = aws_autoscaling_group.asg.name }
  alarm_actions = [aws_autoscaling_policy.cpu_scale_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.app_name}-cpu-low"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 5
  comparison_operator = "LessThanThreshold"

  dimensions = { AutoScalingGroupName = aws_autoscaling_group.asg.name }
  alarm_actions = [aws_autoscaling_policy.cpu_scale_in.arn]
}

resource "aws_lb_target_group" "netdata" {
  name        = "${var.app_name}-netdata"
  port        = 19999
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = local.vpc_id

  health_check {
    protocol = "HTTP"
    port     = "19999"
    path     = "/api/v1/info"   # ou "/"
    matcher  = "200-399"
    interval = 30
    timeout  = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_listener" "netdata_8080" {
  load_balancer_arn = aws_lb.public.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.netdata.arn
  }
}


resource "aws_lb_listener_rule" "netdata_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    host_header {
      values = ["netdata.example.com"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.netdata.arn
  }
}

