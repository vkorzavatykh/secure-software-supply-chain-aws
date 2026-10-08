# Instance bootstrap, rendered from deployment/user-data into gzip-compressed cloud-init user_data. The
# running configuration always traces back to a commit, and any change replaces the instance (ADR-009).
# Compression keeps it under the 16 KB user_data limit as the bootstrap grows.

locals {
  # Docker Compose isn't packaged for Amazon Linux 2023. Pinned release, verified against this SHA-256 of
  # docker-compose-linux-x86_64. Dependabot can't see this pin; update it by hand.
  compose_version = "5.6.0"
  compose_sha256  = "40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a"

  user_data_dir = "${path.module}/../../../deployment/user-data"
}

data "cloudinit_config" "dtrack" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "10-host.sh"
    content_type = "text/x-shellscript"
    content = templatefile("${local.user_data_dir}/10-host.sh.tftpl", {
      region          = var.region
      log_group       = local.log_group_name
      compose_version = local.compose_version
      compose_sha256  = local.compose_sha256
    })
  }
}
