locals {
  glue_catalog_arn  = "arn:${local.partition}:glue:${var.aws_region}:${local.account_id}:catalog"
  glue_database_arn = "arn:${local.partition}:glue:${var.aws_region}:${local.account_id}:database/${aws_glue_catalog_database.lakehouse.name}"
  glue_tables_arn   = "arn:${local.partition}:glue:${var.aws_region}:${local.account_id}:table/${aws_glue_catalog_database.lakehouse.name}/*"
  glue_lakehouse    = [local.glue_catalog_arn, local.glue_database_arn, local.glue_tables_arn]

  glue_read_actions  = ["glue:GetCatalog", "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables"]
  glue_write_actions = ["glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable"]
  kms_actions        = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]

  # Built from the name rather than read from aws_iam_role.snowflake, so the
  # Snowflake objects can be created before the role. That breaks the
  # role <-> Snowflake dependency cycle and allows a single apply.
  snowflake_role_name = "${var.project}-snowflake"
  snowflake_role_arn  = "arn:${local.partition}:iam::${local.account_id}:role/${local.snowflake_role_name}"
}

# ---------------------------------------------------------------------------
# Reusable access policies for AWS compute (Glue job, EMR, Athena users).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lakehouse_read" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.lakehouse.arn]
  }
  statement {
    sid       = "ReadObjects"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.lakehouse.arn}/*"]
  }
  statement {
    sid       = "UseKmsKey"
    actions   = local.kms_actions
    resources = [aws_kms_key.lakehouse.arn]
  }
  statement {
    sid       = "ReadGlueCatalog"
    actions   = concat(local.glue_read_actions, ["glue:GetPartitions", "glue:BatchGetPartition"])
    resources = local.glue_lakehouse
  }
}

data "aws_iam_policy_document" "lakehouse_write" {
  source_policy_documents = [data.aws_iam_policy_document.lakehouse_read.json]

  statement {
    sid       = "WriteObjects"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.lakehouse.arn}/*"]
  }
  statement {
    sid       = "WriteGlueCatalog"
    actions   = local.glue_write_actions
    resources = local.glue_lakehouse
  }
}

# ---------------------------------------------------------------------------
# IAM role assumed by Snowflake for the external volume (S3) and the catalog
# integration (Glue Iceberg REST, SigV4). Trust values come from the Snowflake
# resources in snowflake.tf.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "snowflake_trust" {
  statement {
    sid     = "SnowflakeAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.snowflake_iam_user_arns
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [random_uuid.snowflake_external_id.result]
    }
  }
}

resource "aws_iam_role" "snowflake" {
  name                 = local.snowflake_role_name
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
    actions   = local.kms_actions
    resources = [aws_kms_key.lakehouse.arn]
  }

  statement {
    sid       = "GlueIcebergCatalog"
    actions   = concat(local.glue_read_actions, var.allow_snowflake_writes ? local.glue_write_actions : [])
    resources = local.glue_lakehouse
  }
}

resource "aws_iam_role_policy" "snowflake_access" {
  name   = "iceberg-access"
  role   = aws_iam_role.snowflake.id
  policy = data.aws_iam_policy_document.snowflake_access.json
}

# IAM changes take a few seconds to reach STS; Snowflake objects that use the
# role straight away (linked database, managed Iceberg table) wait for this.
resource "time_sleep" "snowflake_role_propagation" {
  create_duration = "30s"

  triggers = {
    trust  = aws_iam_role.snowflake.assume_role_policy
    policy = aws_iam_role_policy.snowflake_access.policy
  }
}
