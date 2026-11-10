# ---------------------------------------------------------------------------
# Optional AWS Glue 5.0 Spark job that maintains Iceberg tables in the Glue
# catalog. Glue 5.0 ships Iceberg natively (--datalake-formats=iceberg).
# ---------------------------------------------------------------------------

locals {
  glue_job_script = "${path.module}/../ingest/glue_job/iceberg_etl.py"
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
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.lakehouse.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.lakehouse.arn}/*"]
  }

  statement {
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.lakehouse.arn]
  }

  statement {
    actions = [
      "glue:GetCatalog", "glue:GetDatabase", "glue:GetDatabases",
      "glue:GetTable", "glue:GetTables", "glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable",
    ]
    resources = [local.glue_catalog_arn, local.glue_database_arn, local.glue_tables_arn]
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

  name              = "${var.project}-iceberg-etl"
  role_arn          = aws_iam_role.glue_job[0].arn
  glue_version      = "5.0"
  worker_type       = var.glue_job_worker_type
  number_of_workers = var.glue_job_number_of_workers
  timeout           = 60

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.lakehouse.bucket}/${aws_s3_object.glue_job_script[0].key}"
  }

  default_arguments = {
    "--datalake-formats"                 = "iceberg"
    "--enable-glue-datacatalog"          = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${aws_s3_bucket.lakehouse.bucket}/glue/tmp/"
    "--DATABASE"                         = aws_glue_catalog_database.lakehouse.name
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
