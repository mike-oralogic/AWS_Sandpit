# ---------------------------------------------------------------------------
# IAM role assumed by Snowflake.
#
# One role serves both the external volume (S3 data access) and the catalog
# integration (Glue Iceberg REST catalog via SigV4). Snowflake issues one
# external ID per object, so the trust policy accepts every ID passed in.
# ---------------------------------------------------------------------------

locals {
  snowflake_trust_ready = length(var.snowflake_iam_user_arns) > 0 && length(var.snowflake_external_ids) > 0

  glue_catalog_arn  = "arn:${local.partition}:glue:${var.aws_region}:${local.account_id}:catalog"
  glue_database_arn = "arn:${local.partition}:glue:${var.aws_region}:${local.account_id}:database/${aws_glue_catalog_database.lakehouse.name}"
  glue_tables_arn   = "arn:${local.partition}:glue:${var.aws_region}:${local.account_id}:table/${aws_glue_catalog_database.lakehouse.name}/*"
}

data "aws_iam_policy_document" "snowflake_trust" {
  statement {
    sid     = "SnowflakeAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      # Phase 1: Snowflake's IAM user is not known yet, so trust only this
      # account with an external ID nobody uses. The role is unusable until
      # phase 2 fills in the real values.
      identifiers = local.snowflake_trust_ready ? var.snowflake_iam_user_arns : ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = local.snowflake_trust_ready ? var.snowflake_external_ids : ["pending-snowflake-setup"]
    }
  }
}

resource "aws_iam_role" "snowflake" {
  name                 = "${var.project}-snowflake"
  description          = "Assumed by Snowflake for the Iceberg external volume and Glue catalog integration"
  assume_role_policy   = data.aws_iam_policy_document.snowflake_trust.json
  max_session_duration = 43200
}

data "aws_iam_policy_document" "snowflake_access" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.lakehouse.arn]
  }

  statement {
    sid = "ObjectAccess"
    actions = concat(
      ["s3:GetObject", "s3:GetObjectVersion"],
      var.allow_snowflake_writes ? ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"] : [],
    )
    resources = ["${aws_s3_bucket.lakehouse.arn}/*"]
  }

  statement {
    sid       = "UseKmsKey"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.lakehouse.arn]
  }

  statement {
    sid = "GlueIcebergCatalog"
    actions = concat(
      ["glue:GetCatalog", "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables"],
      var.allow_snowflake_writes ? ["glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable"] : [],
    )
    resources = [local.glue_catalog_arn, local.glue_database_arn, local.glue_tables_arn]
  }
}

resource "aws_iam_role_policy" "snowflake_access" {
  name   = "iceberg-access"
  role   = aws_iam_role.snowflake.id
  policy = data.aws_iam_policy_document.snowflake_access.json
}
