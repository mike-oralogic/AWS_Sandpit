# ---------------------------------------------------------------------------
# AWS Glue 5.0 Spark job (diagram step 1, "AWS Glue ETL"):
#   1. Glue Data Quality gate on the source Iceberg tables
#   2. MERGE orders + customers into orders_enriched
#   3. Iceberg maintenance (compaction, snapshot expiry)
# Glue 5.0 ships Iceberg natively (--datalake-formats=iceberg).
# ---------------------------------------------------------------------------

locals {
  glue_job_script = "${path.module}/../ingest/glue_job/iceberg_etl.py"
  glue_job_name   = "${var.project}-iceberg-etl"
  dq_metric_ns    = "IcebergLakehouse/DataQuality"
}

resource "aws_s3_object" "glue_job_script" {
  count = var.enable_glue_job ? 1 : 0

  bucket = aws_s3_bucket.lakehouse.id
  key    = "glue/scripts/iceberg_etl.py"
  source = local.glue_job_script
  etag   = filemd5(local.glue_job_script)
}

data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_job" {
  count = var.enable_glue_job ? 1 : 0

  name               = "${var.project}-glue-job"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  count = var.enable_glue_job ? 1 : 0

  role       = aws_iam_role.glue_job[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_job_access" {
  source_policy_documents = [data.aws_iam_policy_document.lakehouse_write.json]

  statement {
    sid       = "DataQuality"
    actions   = ["glue:GetDataQualityRuleset", "glue:PublishDataQuality"]
    resources = ["*"]
  }

  statement {
    sid       = "DataQualityMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.dq_metric_ns, "Glue Data Quality"]
    }
  }

  statement {
    sid       = "JobLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.glue_job.arn}:*"]
  }
}

resource "aws_iam_role_policy" "glue_job_access" {
  count = var.enable_glue_job ? 1 : 0

  name   = "iceberg-access"
  role   = aws_iam_role.glue_job[0].id
  policy = data.aws_iam_policy_document.glue_job_access.json
}

resource "aws_glue_job" "iceberg_etl" {
  count = var.enable_glue_job ? 1 : 0

  name              = local.glue_job_name
  role_arn          = aws_iam_role.glue_job[0].arn
  glue_version      = "5.0"
  worker_type       = var.glue_job_worker_type
  number_of_workers = var.glue_job_number_of_workers
  timeout           = 60

  execution_property {
    max_concurrent_runs = 1
  }

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.lakehouse.bucket}/${aws_s3_object.glue_job_script[0].key}"
  }

  default_arguments = {
    "--datalake-formats"        = "iceberg"
    "--enable-glue-datacatalog" = "true"
    "--job-language"            = "python"
    "--TempDir"                 = "s3://${aws_s3_bucket.lakehouse.bucket}/glue/tmp/"

    # Observability: job metrics, Spark observability metrics, job run
    # insights and continuous logging to a dedicated log group.
    "--enable-metrics"                   = "true"
    "--enable-observability-metrics"     = "true"
    "--enable-job-insights"              = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-continuous-log-filter"     = "true"
    "--continuous-log-logGroup"          = aws_cloudwatch_log_group.glue_job.name

    # Job parameters read by iceberg_etl.py
    "--DATABASE"            = aws_glue_catalog_database.lakehouse.name
    "--DQ_RULESETS"         = jsonencode({ for k, r in aws_glue_data_quality_ruleset.lakehouse : k => r.name })
    "--DQ_FAIL_ON_ERROR"    = tostring(var.dq_fail_job_on_error)
    "--DQ_METRIC_NAMESPACE" = local.dq_metric_ns

    "--conf" = join(" --conf ", [
      "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
      "spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog",
      "spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog",
      "spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO",
      "spark.sql.catalog.glue_catalog.warehouse=s3://${aws_s3_bucket.lakehouse.bucket}/${local.warehouse_prefix}",
    ])
  }

  depends_on = [aws_iam_role_policy.glue_job_access, aws_iam_role_policy_attachment.glue_service]
}

resource "aws_glue_trigger" "iceberg_etl_schedule" {
  count = var.enable_glue_job && var.glue_job_schedule != null ? 1 : 0

  name     = "${local.glue_job_name}-schedule"
  type     = "SCHEDULED"
  schedule = var.glue_job_schedule

  actions {
    job_name = aws_glue_job.iceberg_etl[0].name
  }
}
