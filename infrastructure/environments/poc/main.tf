# The per-session environment: created at the start of a work session and destroyed at its end
# (runbook §2). Long-lived parts (state bucket, CI roles, DNS zone, certificate) come from the bootstrap
# stack and are looked up by name.

locals {
  # Host ports of the Dependency-Track frontend and apiserver, shared by the Security Groups and the
  # load balancer target groups.
  app_ports = {
    ui  = 8080
    api = 8081
  }

  log_group_name = "/sssc/dependency-track"
}

data "aws_route53_zone" "dtrack" {
  name         = var.dtrack_domain
  private_zone = false
}

data "aws_acm_certificate" "dtrack" {
  domain      = var.dtrack_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

module "network" {
  source = "../../modules/network"

  availability_zones    = var.availability_zones
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  app_ports             = local.app_ports
}

module "database" {
  source = "../../modules/database"

  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.db_security_group_id
  instance_class    = var.db_instance_class
}

module "compute" {
  source = "../../modules/compute"

  subnet_id            = module.network.app_subnet_ids[0]
  security_group_id    = module.network.app_security_group_id
  instance_type        = var.instance_type
  user_data_base64     = data.cloudinit_config.dtrack.rendered
  db_master_secret_arn = module.database.master_user_secret_arn
  log_group_name       = local.log_group_name
}

module "edge" {
  source = "../../modules/edge"

  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.public_subnet_ids
  security_group_id  = module.network.alb_security_group_id
  certificate_arn    = data.aws_acm_certificate.dtrack.arn
  zone_id            = data.aws_route53_zone.dtrack.zone_id
  domain_name        = var.dtrack_domain
  target_instance_id = module.compute.instance_id
  app_ports          = local.app_ports
  dtrack_public      = var.dtrack_public
}
