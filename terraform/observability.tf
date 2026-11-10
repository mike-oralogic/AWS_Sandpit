# ---------------------------------------------------------------------------
# Observability (diagram step 2): logs, alerts and a dashboard.
#   - Glue job logs in a dedicated log group with retention
#   - SNS topic for alerts (optional email subscription)
#   - EventBridge: Glue job FAILED / TIMEOUT / ERROR -> SNS
#   - CloudWatch alarms: Data Quality rule failures per table -> SNS
#   - CloudWatch dashboard: job, data quality, storage, Athena
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "glue_job" {
  name              = "/aws-glue/jobs/${var.project}"
  retention_in_days = var.log_retention_days
}

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "EventBridgeAndCloudWatch"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_cloudwatch_event_rule" "glue_job_failed" {
  count = var.enable_glue_job ? 1 : 0

  name        = "${var.project}-glue-job-failed"
  description = "Glue Iceberg job did not succeed"
  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.iceberg_etl[0].name]
      state   = ["FAILED", "TIMEOUT", "ERROR"]
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_job_failed" {
  count = var.enable_glue_job ? 1 : 0

  rule = aws_cloudwatch_event_rule.glue_job_failed[0].name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      job   = "$.detail.jobName"
      run   = "$.detail.jobRunId"
      state = "$.detail.state"
      msg   = "$.detail.message"
    }
    input_template = "\"Glue job <job> run <run> ended in state <state>: <msg>\""
  }
}

resource "aws_cloudwatch_metric_alarm" "dq_rules_failed" {
  for_each = var.enable_glue_job ? aws_glue_data_quality_ruleset.lakehouse : {}

  alarm_name          = "${var.project}-dq-${each.key}"
  alarm_description   = "Glue Data Quality rules failed for ${var.glue_database_name}.${each.key}"
  namespace           = local.dq_metric_ns
  metric_name         = "RulesFailed"
  dimensions          = { Table = each.key }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

locals {
  dq_tables = keys(local.dq_rulesets)

  dashboard_widgets = [
    {
      type = "text", x = 0, y = 0, width = 24, height = 2
      properties = {
        markdown = "## ${var.project} — Iceberg lakehouse\nGlue job `${local.glue_job_name}` · Glue DB `${var.glue_database_name}` · bucket `${aws_s3_bucket.lakehouse.bucket}` · Athena workgroup `${aws_athena_workgroup.lakehouse.name}`"
      }
    },
    {
      type = "metric", x = 0, y = 2, width = 12, height = 6
      properties = {
        title  = "Data Quality: rules failed / passed"
        region = var.aws_region
        stat   = "Maximum"
        period = 300
        metrics = concat(
          [for t in local.dq_tables : [local.dq_metric_ns, "RulesFailed", "Table", t, { label = "${t} failed" }]],
          [for t in local.dq_tables : [local.dq_metric_ns, "RulesPassed", "Table", t, { label = "${t} passed" }]],
        )
      }
    },
    {
      type = "metric", x = 12, y = 2, width = 12, height = 6
      properties = {
        title  = "Glue job: elapsed time (ms) and failed tasks"
        region = var.aws_region
        period = 300
        metrics = [
          [{ expression = "SEARCH('{Glue,JobName,JobRunId,Type} JobName=\"${local.glue_job_name}\" MetricName=\"glue.driver.aggregate.elapsedTime\"', 'Maximum', 300)", id = "elapsed" }],
          [{ expression = "SEARCH('{Glue,JobName,JobRunId,Type} JobName=\"${local.glue_job_name}\" MetricName=\"glue.driver.aggregate.numFailedTasks\"', 'Sum', 300)", id = "failed" }],
        ]
      }
    },
    {
      type = "metric", x = 0, y = 8, width = 12, height = 6
      properties = {
        title  = "S3 lakehouse bucket size and objects (daily)"
        region = var.aws_region
        stat   = "Average"
        period = 86400
        metrics = [
          ["AWS/S3", "BucketSizeBytes", "BucketName", aws_s3_bucket.lakehouse.bucket, "StorageType", "StandardStorage"],
          ["AWS/S3", "NumberOfObjects", "BucketName", aws_s3_bucket.lakehouse.bucket, "StorageType", "AllStorageTypes", { yAxis = "right" }],
        ]
      }
    },
    {
      type = "metric", x = 12, y = 8, width = 12, height = 6
      properties = {
        title  = "Athena: data scanned and query time"
        region = var.aws_region
        period = 300
        metrics = [
          [{ expression = "SEARCH('{AWS/Athena,QueryState,QueryType,WorkGroup} WorkGroup=\"${aws_athena_workgroup.lakehouse.name}\" MetricName=\"ProcessedBytes\"', 'Sum', 300)", id = "bytes" }],
          [{ expression = "SEARCH('{AWS/Athena,QueryState,QueryType,WorkGroup} WorkGroup=\"${aws_athena_workgroup.lakehouse.name}\" MetricName=\"TotalExecutionTime\"', 'Average', 300)", id = "time" }],
        ]
      }
    },
    {
      type = "log", x = 0, y = 14, width = 24, height = 6
      properties = {
        title  = "Glue job errors"
        region = var.aws_region
        query  = "SOURCE '${aws_cloudwatch_log_group.glue_job.name}' | fields @timestamp, @logStream, @message | filter @message like /(?i)(error|exception|dq rule failed)/ | sort @timestamp desc | limit 50"
        view   = "table"
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "lakehouse" {
  dashboard_name = var.project
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
