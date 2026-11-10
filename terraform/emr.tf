# ---------------------------------------------------------------------------
# Amazon EMR Serverless (diagram "Consumers"), optional. A Spark application
# that reads the Glue Iceberg tables. It starts on job submission and stops
# when idle, so it costs nothing between runs.
# ---------------------------------------------------------------------------

locals {
  emr_script = "${path.module}/../ingest/emr/iceberg_report.py"
}

resource "aws_emrserverless_application" "spark" {
  count = var.enable_emr_serverless ? 1 : 0

  name          = "${var.project}-spark"
  release_label = var.emr_release_label
  type          = "spark"

  auto_start_configuration {
    enabled = true
  }

  auto_stop_configuration {
    enabled              = true
    idle_timeout_minutes = 15
  }

  maximum_capacity {
    cpu    = "16 vCPU"
    memory = "64 GB"
  }
}

data "aws_iam_policy_document" "emr_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["emr-serverless.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "emr_job" {
  count = var.enable_emr_serverless ? 1 : 0

  name               = "${var.project}-emr-job"
  assume_role_policy = data.aws_iam_policy_document.emr_trust.json
}

data "aws_iam_policy_document" "emr_job_access" {
  source_policy_documents = [data.aws_iam_policy_document.lakehouse_read.json]

  statement {
    sid       = "Logs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.lakehouse.arn}/emr/logs/*"]
  }
}

resource "aws_iam_role_policy" "emr_job_access" {
  count = var.enable_emr_serverless ? 1 : 0

  name   = "iceberg-read"
  role   = aws_iam_role.emr_job[0].id
  policy = data.aws_iam_policy_document.emr_job_access.json
}

resource "aws_s3_object" "emr_script" {
  count = var.enable_emr_serverless ? 1 : 0

  bucket = aws_s3_bucket.lakehouse.id
  key    = "emr/scripts/iceberg_report.py"
  source = local.emr_script
  etag   = filemd5(local.emr_script)
}

locals {
  emr_spark_params = join(" ", [
    "--conf spark.jars=/usr/share/aws/iceberg/lib/iceberg-spark3-runtime.jar",
    "--conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
    "--conf spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog",
    "--conf spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog",
    "--conf spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO",
    "--conf spark.sql.catalog.glue_catalog.warehouse=s3://${aws_s3_bucket.lakehouse.bucket}/${local.warehouse_prefix}",
  ])

  emr_start_job_run_command = var.enable_emr_serverless ? join(" ", [
    "aws emr-serverless start-job-run",
    "--region ${var.aws_region}",
    "--application-id ${aws_emrserverless_application.spark[0].id}",
    "--execution-role-arn ${aws_iam_role.emr_job[0].arn}",
    "--name iceberg-report",
    "--job-driver '${jsonencode({ sparkSubmit = {
      entryPoint            = "s3://${aws_s3_bucket.lakehouse.bucket}/${aws_s3_object.emr_script[0].key}"
      entryPointArguments   = [var.glue_database_name]
      sparkSubmitParameters = local.emr_spark_params
    } })}'",
    "--configuration-overrides '${jsonencode({ monitoringConfiguration = {
      s3MonitoringConfiguration = { logUri = "s3://${aws_s3_bucket.lakehouse.bucket}/emr/logs/" }
    } })}'",
  ]) : null
}
