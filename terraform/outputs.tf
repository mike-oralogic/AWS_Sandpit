output "aws_account_id" {
  value = local.account_id
}

output "aws_region" {
  value = var.aws_region
}

output "bucket_name" {
  value = aws_s3_bucket.lakehouse.bucket
}

output "warehouse_uri" {
  description = "Iceberg warehouse root for Glue-managed tables."
  value       = "s3://${aws_s3_bucket.lakehouse.bucket}/${local.warehouse_prefix}"
}

output "external_volume_base_url" {
  description = "STORAGE_BASE_URL for the Snowflake external volume. Covers the whole bucket so Glue- and Snowflake-managed tables share one volume."
  value       = "s3://${aws_s3_bucket.lakehouse.bucket}/"
}

output "kms_key_arn" {
  value = aws_kms_key.lakehouse.arn
}

output "glue_database" {
  value = aws_glue_catalog_database.lakehouse.name
}

output "glue_iceberg_rest_uri" {
  description = "AWS Glue Iceberg REST catalog endpoint used by the Snowflake catalog integration."
  value       = "https://glue.${var.aws_region}.amazonaws.com/iceberg"
}

output "snowflake_role_arn" {
  description = "STORAGE_AWS_ROLE_ARN for the external volume and SIGV4_IAM_ROLE for the catalog integration."
  value       = aws_iam_role.snowflake.arn
}

output "snowflake_trust_configured" {
  description = "false until Snowflake's IAM user ARN and external IDs have been applied (phase 2)."
  value       = local.snowflake_trust_ready
}

output "glue_job_name" {
  value = var.enable_glue_job ? aws_glue_job.iceberg_etl[0].name : null
}
