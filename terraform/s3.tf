locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  bucket_name = coalesce(var.bucket_name, "${var.project}-${local.account_id}-${var.aws_region}")

  # Glue-managed tables live under warehouse/<db>.db/<table>;
  # Snowflake-managed Iceberg tables live under snowflake_managed/.
  warehouse_prefix = "warehouse"
}

resource "aws_kms_key" "lakehouse" {
  description             = "${var.project} Iceberg data encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "lakehouse" {
  name          = "alias/${var.project}"
  target_key_id = aws_kms_key.lakehouse.key_id
}

resource "aws_s3_bucket" "lakehouse" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy_bucket
}

resource "aws_s3_bucket_public_access_block" "lakehouse" {
  bucket                  = aws_s3_bucket.lakehouse.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.lakehouse.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.lakehouse]
}

data "aws_iam_policy_document" "bucket_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.lakehouse.arn,
      "${aws_s3_bucket.lakehouse.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "lakehouse" {
  bucket = aws_s3_bucket.lakehouse.id
  policy = data.aws_iam_policy_document.bucket_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.lakehouse]
}
