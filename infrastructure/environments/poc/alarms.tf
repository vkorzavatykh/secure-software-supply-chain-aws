# Three alarms and an email topic (architecture §8). No dashboards, tracing or SIEM in the MVP.

# Not encrypted with KMS: CloudWatch can't publish to a topic encrypted with the AWS-managed SNS key, and
# alarm messages carry no secrets.
resource "aws_sns_topic" "alarms" {
  name = "sssc-alarms"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count = nonsensitive(var.alarm_email != "") ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# The worse of the two target groups. While the startup barrier is closed, no listener uses them, so
# there is no data and the alarm stays OK.
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "sssc-dtrack-unhealthy-targets"
  alarm_description   = "A Dependency-Track target group (UI or API) has had an unhealthy target for 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id          = "unhealthy"
    expression  = "MAX([ui, api])"
    label       = "Unhealthy targets (UI or API)"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = module.edge.target_group_arn_suffixes

    content {
      id = metric_query.key

      metric {
        namespace   = "AWS/ApplicationELB"
        metric_name = "UnHealthyHostCount"
        period      = 60
        stat        = "Maximum"

        dimensions = {
          LoadBalancer = module.edge.alb_arn_suffix
          TargetGroup  = metric_query.value
        }
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "instance_status_check" {
  alarm_name          = "sssc-dtrack-status-check-failed"
  alarm_description   = "The Dependency-Track instance has failed an EC2 status check for 5 minutes."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  dimensions = {
    InstanceId = module.compute.instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "database_free_storage" {
  alarm_name          = "sssc-dtrack-db-free-storage-low"
  alarm_description   = "The Dependency-Track database has less than 2 GiB of free storage."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  dimensions = {
    DBInstanceIdentifier = module.database.identifier
  }
}
