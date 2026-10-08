# Offline tests: the AWS provider is mocked, so no account or credentials are needed.
# They pin down the network properties that architecture §3-4 and ADR-019 promise.

mock_provider "aws" {}

variables {
  availability_zones = ["eu-central-1a", "eu-central-1b"]
}

run "subnet_layout_matches_the_architecture" {
  command = plan

  assert {
    condition     = [for az in var.availability_zones : aws_subnet.public[az].cidr_block] == ["10.20.0.0/24", "10.20.1.0/24"]
    error_message = "Public subnets must be 10.20.0.0/24 and 10.20.1.0/24."
  }

  assert {
    condition     = [for az in var.availability_zones : aws_subnet.app[az].cidr_block] == ["10.20.10.0/24", "10.20.11.0/24"]
    error_message = "Private app subnets must be 10.20.10.0/24 and 10.20.11.0/24."
  }

  assert {
    condition     = [for az in var.availability_zones : aws_subnet.data[az].cidr_block] == ["10.20.20.0/24", "10.20.21.0/24"]
    error_message = "Private data subnets must be 10.20.20.0/24 and 10.20.21.0/24."
  }

  assert {
    condition     = alltrue([for subnet in concat(values(aws_subnet.public), values(aws_subnet.app), values(aws_subnet.data)) : subnet.map_public_ip_on_launch == false])
    error_message = "No subnet may assign public IPs to instances."
  }
}

run "only_the_app_tier_reaches_the_internet_through_nat" {
  command = apply

  assert {
    condition     = aws_route.public_internet.route_table_id == aws_route_table.public.id && aws_route.public_internet.gateway_id == aws_internet_gateway.this.id
    error_message = "The public route table must route to the Internet Gateway."
  }

  assert {
    condition     = aws_route.app_internet.route_table_id == aws_route_table.app.id && aws_route.app_internet.nat_gateway_id == aws_nat_gateway.this.id
    error_message = "The app route table must route outbound traffic through the NAT Gateway."
  }

  assert {
    condition     = !contains([aws_route.public_internet.route_table_id, aws_route.app_internet.route_table_id], aws_route_table.data.id)
    error_message = "No internet route may be attached to the data route table."
  }

  assert {
    condition     = alltrue([for association in aws_route_table_association.data : association.route_table_id == aws_route_table.data.id])
    error_message = "Every data subnet must use the data route table."
  }

  assert {
    condition     = aws_nat_gateway.this.subnet_id == aws_subnet.public["eu-central-1a"].id
    error_message = "The single NAT Gateway must sit in the first AZ's public subnet (ADR-007)."
  }
}

run "security_groups_follow_the_matrix" {
  command = apply

  assert {
    condition = alltrue([
      for rule in concat(
        values(aws_vpc_security_group_ingress_rule.alb_https),
        values(aws_vpc_security_group_ingress_rule.alb_http),
        values(aws_vpc_security_group_ingress_rule.app_from_alb),
        [aws_vpc_security_group_ingress_rule.db_from_app],
      ) : !(rule.from_port <= 22 && rule.to_port >= 22)
    ])
    error_message = "No ingress rule may include port 22."
  }

  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.app_from_alb : rule.referenced_security_group_id == aws_security_group.alb.id && rule.cidr_ipv4 == null])
    error_message = "The app tier must accept traffic only from the load balancer's Security Group."
  }

  assert {
    condition     = toset([for rule in aws_vpc_security_group_ingress_rule.app_from_alb : rule.from_port]) == toset([8080, 8081])
    error_message = "The app tier must accept exactly the UI (8080) and API (8081) ports."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_app.referenced_security_group_id == aws_security_group.app.id && aws_vpc_security_group_ingress_rule.db_from_app.from_port == 5432
    error_message = "The database must accept PostgreSQL only from the app tier's Security Group."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.app_to_db.referenced_security_group_id == aws_security_group.db.id
    error_message = "The app tier must reach PostgreSQL through a Security Group reference."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.alb_https)) == toset(["0.0.0.0/0"])
    error_message = "By default the load balancer is open to the internet on 443."
  }
}

run "allowed_ingress_cidrs_narrow_the_load_balancer" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["203.0.113.10/32", "198.51.100.0/24"]
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.alb_https)) == toset(["198.51.100.0/24", "203.0.113.10/32"])
    error_message = "HTTPS ingress must follow allowed_ingress_cidrs exactly."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.alb_http)) == toset(["198.51.100.0/24", "203.0.113.10/32"])
    error_message = "HTTP ingress must follow allowed_ingress_cidrs exactly."
  }
}

run "rejects_a_single_availability_zone" {
  command = plan

  variables {
    availability_zones = ["eu-central-1a"]
  }

  expect_failures = [var.availability_zones]
}

run "rejects_an_invalid_ingress_range" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["everyone"]
  }

  expect_failures = [var.allowed_ingress_cidrs]
}
