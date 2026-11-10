# ---------------------------------------------------------------------------
# Amazon Athena (diagram "Consumers"): engine v3 reads and writes the Glue
# Iceberg tables directly. Results are KMS-encrypted in the lakehouse bucket.
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "lakehouse" {
  name          = var.project
  description   = "Queries over the ${var.glue_database_name} Iceberg tables"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.lakehouse.bucket}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.lakehouse.arn
      }
    }
  }
}

locals {
  athena_queries = {
    revenue-by-region = {
      description = "Order count and revenue per region"
      query       = <<-SQL
        SELECT region, COUNT(*) AS orders, SUM(amount) AS revenue
        FROM "${var.glue_database_name}"."orders"
        GROUP BY region
        ORDER BY revenue DESC
      SQL
    }
    orders-snapshots = {
      description = "Iceberg snapshot history of the orders table"
      query       = <<-SQL
        SELECT committed_at, snapshot_id, operation, summary
        FROM "${var.glue_database_name}"."orders$snapshots"
        ORDER BY committed_at DESC
      SQL
    }
    orders-time-travel = {
      description = "Orders as they were one hour ago (Iceberg time travel)"
      query       = <<-SQL
        SELECT region, COUNT(*) AS orders
        FROM "${var.glue_database_name}"."orders"
        FOR TIMESTAMP AS OF (current_timestamp - interval '1' hour)
        GROUP BY region
      SQL
    }
    orders-optimize = {
      description = "Compact small files in the orders table"
      query       = "OPTIMIZE \"${var.glue_database_name}\".\"orders\" REWRITE DATA USING BIN_PACK"
    }
  }
}

resource "aws_athena_named_query" "lakehouse" {
  for_each = local.athena_queries

  name        = each.key
  description = each.value.description
  workgroup   = aws_athena_workgroup.lakehouse.id
  database    = aws_glue_catalog_database.lakehouse.name
  query       = each.value.query
}

# Attach this to the people or roles that query the lakehouse through Athena.
data "aws_iam_policy_document" "athena_user" {
  source_policy_documents = [data.aws_iam_policy_document.lakehouse_read.json]

  statement {
    sid = "UseWorkgroup"
    actions = [
      "athena:StartQueryExecution", "athena:StopQueryExecution", "athena:GetQueryExecution",
      "athena:GetQueryResults", "athena:GetQueryResultsStream", "athena:ListQueryExecutions",
      "athena:GetWorkGroup", "athena:BatchGetQueryExecution",
      "athena:ListNamedQueries", "athena:GetNamedQuery", "athena:BatchGetNamedQuery",
    ]
    resources = [aws_athena_workgroup.lakehouse.arn]
  }

  statement {
    sid       = "QueryResults"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.lakehouse.arn}/athena-results/*"]
  }
}

resource "aws_iam_policy" "athena_user" {
  name        = "${var.project}-athena-user"
  description = "Query the ${var.glue_database_name} Iceberg tables through the ${aws_athena_workgroup.lakehouse.name} Athena workgroup (read-only)"
  policy      = data.aws_iam_policy_document.athena_user.json
}
