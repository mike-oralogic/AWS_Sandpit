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

output "glue_database" {
  value = aws_glue_catalog_database.lakehouse.name
}

output "snowflake_role_arn" {
  description = "IAM role Snowflake assumes for the external volume and the Glue catalog integration."
  value       = aws_iam_role.snowflake.arn
}

output "snowflake" {
  description = "Snowflake objects created by Terraform."
  value = {
    external_volume     = snowflake_external_volume.s3.name
    catalog_integration = snowflake_catalog_integration_iceberg_rest.glue.name
    warehouse           = snowflake_warehouse.iceberg.name
    role                = snowflake_account_role.engineer.name
    linked_database     = local.sf.linked_database
    managed_table       = local.daily_revenue_fqn
    share               = snowflake_share.iceberg.name
  }
}

output "glue_job_name" {
  value = var.enable_glue_job ? aws_glue_job.iceberg_etl[0].name : null
}

output "data_quality_rulesets" {
  value = { for k, r in aws_glue_data_quality_ruleset.lakehouse : k => r.name }
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.lakehouse.dashboard_name}"
}

output "athena_workgroup" {
  value = aws_athena_workgroup.lakehouse.name
}

output "athena_user_policy_arn" {
  description = "Attach to users/roles that should query the lakehouse with Athena."
  value       = aws_iam_policy.athena_user.arn
}

output "emr_serverless_application_id" {
  value = var.enable_emr_serverless ? aws_emrserverless_application.spark[0].id : null
}

output "emr_start_job_run_command" {
  description = "AWS CLI command that runs the Iceberg report on EMR Serverless."
  value       = local.emr_start_job_run_command
}
