# Offline tests with a mocked AWS provider. The most important property here is the startup barrier
# (ADR-020): nothing is forwarded to Dependency-Track unless dtrack_public is explicitly true.

mock_provider "aws" {
  # The provider validates ARNs, so mocked resources get realistic ones.
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-central-1:111111111111:loadbalancer/app/sssc-alb/0123456789abcdef"
      arn_suffix = "app/sssc-alb/0123456789abcdef"
      dns_name   = "sssc-alb-0123456789.eu-central-1.elb.amazonaws.com"
      zone_id    = "Z215JYRZR1TBD5"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-central-1:111111111111:listener/app/sssc-alb/0123456789abcdef/0123456789abcdef"
    }
  }
}

# Distinct ARNs per target group, so the forwarding assertions can tell UI and API apart.
override_resource {
  target = aws_lb_target_group.this["ui"]
  values = {
    arn = "arn:aws:elasticloadbalancing:eu-central-1:111111111111:targetgroup/sssc-dt-ui/1111111111111111"
  }
}

override_resource {
  target = aws_lb_target_group.this["api"]
  values = {
    arn = "arn:aws:elasticloadbalancing:eu-central-1:111111111111:targetgroup/sssc-dt-api/2222222222222222"
  }
}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_ids         = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  security_group_id  = "sg-0123456789abcdef0"
  certificate_arn    = "arn:aws:acm:eu-central-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"
  zone_id            = "Z0000000000000000000"
  domain_name        = "dtrack.example.com"
  target_instance_id = "i-0123456789abcdef0"
}

run "barrier_is_closed_by_default" {
  command = plan

  assert {
    condition     = aws_lb_listener.https.default_action[0].type == "fixed-response"
    error_message = "With dtrack_public unset, the HTTPS listener must not forward anything."
  }

  assert {
    condition     = aws_lb_listener.https.default_action[0].fixed_response[0].status_code == "503"
    error_message = "The closed barrier must answer 503."
  }

  assert {
    condition     = aws_lb_listener.https.default_action[0].target_group_arn == null
    error_message = "The closed barrier must not reference a target group."
  }

  assert {
    condition     = length(aws_lb_listener_rule.api) == 0
    error_message = "No forward rule for /api/* may exist while the barrier is closed."
  }
}

run "open_barrier_forwards_ui_and_api" {
  command = apply

  variables {
    dtrack_public = true
  }

  assert {
    condition     = aws_lb_listener.https.default_action[0].type == "forward" && aws_lb_listener.https.default_action[0].target_group_arn == aws_lb_target_group.this["ui"].arn
    error_message = "With the barrier open, the default action must forward to the UI target group."
  }

  assert {
    condition     = length(aws_lb_listener_rule.api) == 1 && aws_lb_listener_rule.api[0].action[0].target_group_arn == aws_lb_target_group.this["api"].arn
    error_message = "With the barrier open, one rule must forward to the API target group."
  }

  assert {
    condition     = tolist(aws_lb_listener_rule.api[0].condition)[0].path_pattern[0].values == toset(["/api/*"])
    error_message = "The API rule must match /api/* only."
  }
}

run "http_redirects_and_https_is_hardened" {
  command = plan

  assert {
    condition = (
      aws_lb_listener.http.default_action[0].type == "redirect"
      && aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS"
      && aws_lb_listener.http.default_action[0].redirect[0].port == "443"
      && aws_lb_listener.http.default_action[0].redirect[0].status_code == "HTTP_301"
    )
    error_message = "Port 80 must only redirect to HTTPS."
  }

  assert {
    condition     = aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06" && aws_lb_listener.https.certificate_arn == var.certificate_arn
    error_message = "HTTPS must use the TLS 1.2/1.3 policy and the bootstrap certificate."
  }

  assert {
    condition     = aws_lb.this.drop_invalid_header_fields && !aws_lb.this.internal
    error_message = "The public load balancer must drop invalid header fields."
  }
}

run "targets_and_dns" {
  command = plan

  assert {
    condition     = aws_lb_target_group.this["ui"].port == 8080 && aws_lb_target_group.this["api"].port == 8081
    error_message = "Target groups must use the UI (8080) and API (8081) host ports."
  }

  assert {
    condition     = aws_lb_target_group.this["api"].health_check[0].path == "/api/version"
    error_message = "The API target group must check the apiserver's version endpoint."
  }

  assert {
    condition     = aws_route53_record.alias.name == var.domain_name && aws_route53_record.alias.type == "A"
    error_message = "The only DNS change is the A alias at the zone apex (the apply role may change nothing else)."
  }
}
