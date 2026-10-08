# Security Group matrix (architecture §4). Tiers reference each other's groups, not CIDR ranges, and no
# rule anywhere opens port 22. Groups without an egress rule here have no egress at all: Terraform removes
# the default allow-all rule that AWS adds.

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Load balancer: HTTP/HTTPS from allowed ranges; forwards only to the app tier"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app"
  description = "Dependency-Track instance: traffic from the load balancer only"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-app"
  }
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "PostgreSQL: from the Dependency-Track instance only; no egress"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

# --- Load balancer ------------------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP, answered with a redirect to HTTPS"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  for_each = var.app_ports

  security_group_id            = aws_security_group.alb.id
  description                  = "Dependency-Track ${each.key}"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

# --- App tier -----------------------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  for_each = var.app_ports

  security_group_id            = aws_security_group.app.id
  description                  = "Dependency-Track ${each.key} from the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

# Vulnerability feeds, container registries, OS packages, SSM and other AWS APIs are all HTTPS.
# Amazon Linux 2023 repositories are served over HTTPS too, so there is no port 80 egress.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to the internet through the NAT Gateway"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}

# --- Data tier ----------------------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the Dependency-Track instance"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}
