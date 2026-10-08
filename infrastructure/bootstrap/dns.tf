# Delegated subdomain for Dependency-Track (ADR-011). The zone, its CAA record and the certificate stay for
# the whole project, so the NS delegation at the parent domain and the validated certificate don't change
# between sessions. The environment only adds the alias record at the zone apex.

resource "aws_route53_zone" "dtrack" {
  name    = var.dtrack_domain
  comment = "Dependency-Track proof of concept, delegated from the parent domain"
}

# Only Amazon's CA may issue certificates here, whatever the parent domain's CAA policy says.
resource "aws_route53_record" "caa" {
  zone_id = aws_route53_zone.dtrack.zone_id
  name    = var.dtrack_domain
  type    = "CAA"
  ttl     = 3600
  records = ["0 issue \"amazon.com\""]
}

resource "aws_acm_certificate" "dtrack" {
  domain_name       = var.dtrack_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_route53_record.caa]
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.dtrack.domain_validation_options : option.domain_name => option
  }

  zone_id         = aws_route53_zone.dtrack.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 300
  records         = [each.value.resource_record_value]
  allow_overwrite = true
}

# Completes only once ACM can resolve the validation record, which needs the NS delegation at the parent
# domain (runbook §1). If this times out before the delegation propagates, run apply again.
resource "aws_acm_certificate_validation" "dtrack" {
  certificate_arn         = aws_acm_certificate.dtrack.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]

  timeouts {
    create = "30m"
  }
}

# The apply role may change exactly one record in this zone: the A alias at the apex, pointing to the
# environment's load balancer. It can't touch the CAA, NS or validation records.
data "aws_iam_policy_document" "tf_apply_dns" {
  statement {
    sid       = "ManageApexAliasRecordOnly"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.dtrack.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [lower(var.dtrack_domain)]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["A"]
    }
  }

  statement {
    sid       = "ReadProjectZone"
    actions   = ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
    resources = [aws_route53_zone.dtrack.arn]
  }

  statement {
    sid       = "FindZoneAndTrackChanges"
    actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:GetChange"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "tf_apply_dns" {
  name   = "terraform-apply-dns"
  role   = aws_iam_role.ci["tf-apply"].id
  policy = data.aws_iam_policy_document.tf_apply_dns.json
}
