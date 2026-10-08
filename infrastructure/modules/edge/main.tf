# Public edge (architecture §5): one HTTPS load balancer serves the Dependency-Track frontend and API from
# the same origin. /api/* goes to the apiserver, everything else to the frontend, and HTTP redirects to
# HTTPS.

locals {
  target_groups = {
    for name in ["ui", "api"] : name => {
      port              = var.app_ports[name]
      health_check_path = var.health_check_paths[name]
    }
  }
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.security_group_id]
  subnets            = var.subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = false
  # Access logs are off in the MVP: they need an S3 bucket and policy (architecture §8).
}

resource "aws_lb_target_group" "this" {
  for_each = local.target_groups

  name                 = "${var.name_prefix}-dt-${each.key}"
  vpc_id               = var.vpc_id
  target_type          = "instance"
  protocol             = "HTTP"
  port                 = each.value.port
  deregistration_delay = 30

  health_check {
    path                = each.value.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# The instance stays registered all the time. While dtrack_public is false, no listener uses these target
# groups, so the load balancer sends them neither traffic nor health checks.
resource "aws_lb_target_group_attachment" "this" {
  for_each = local.target_groups

  target_group_arn = aws_lb_target_group.this[each.key].arn
  target_id        = var.target_instance_id
  port             = each.value.port
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Startup barrier (ADR-020). A fresh environment starts with Dependency-Track's default admin credentials,
# and health checks can't hold traffic back (an ALB routes after one passing check and fails open when all
# targets are unhealthy). So until bootstrap has replaced the credentials and verified that they no
# longer work, the only answer is a fixed 503 and no forward action exists anywhere.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = var.dtrack_public ? "forward" : "fixed-response"
    target_group_arn = var.dtrack_public ? aws_lb_target_group.this["ui"].arn : null

    dynamic "fixed_response" {
      for_each = var.dtrack_public ? [] : [1]

      content {
        content_type = "text/plain"
        message_body = "503 Starting"
        status_code  = "503"
      }
    }
  }
}

resource "aws_lb_listener_rule" "api" {
  count = var.dtrack_public ? 1 : 0

  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["api"].arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

# The load balancer's name changes with every environment; the hostname doesn't (ADR-011). This record is
# destroyed with the environment, so nothing points at a deleted load balancer between sessions.
resource "aws_route53_record" "alias" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}
