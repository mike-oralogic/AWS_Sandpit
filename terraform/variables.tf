# ---------------------------------------------------------------------------
# General / AWS storage
# ---------------------------------------------------------------------------

variable "project" {
  description = "Short name used to prefix every AWS resource."
  type        = string
  default     = "iceberg-lakehouse"
}

variable "aws_region" {
  description = "AWS region for S3, Glue, Athena and EMR. Should match your Snowflake account region to avoid egress costs."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "S3 bucket for Iceberg data and metadata. Leave null to derive one from project + account id + region."
  type        = string
  default     = null
}

variable "glue_database_name" {
  description = "Glue database (Iceberg namespace) that holds the tables."
  type        = string
  default     = "lakehouse"
}

variable "force_destroy_bucket" {
  description = "Allow `terraform destroy` to delete a non-empty bucket. Keep false outside of sandboxes."
  type        = bool
  default     = false
}

variable "noncurrent_version_expiration_days" {
  description = "Days before noncurrent S3 object versions expire. Iceberg keeps its own snapshots, so this only guards against accidental overwrites."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Extra tags applied to every AWS resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Snowflake
# ---------------------------------------------------------------------------

variable "snowflake_admin_role" {
  description = "Role Terraform uses in Snowflake. Needs to create external volumes, integrations, databases, warehouses, roles and shares."
  type        = string
  default     = "ACCOUNTADMIN"
}

variable "allow_snowflake_writes" {
  description = "Let Snowflake write to S3 and Glue so it can INSERT/UPDATE/CREATE Glue-managed Iceberg tables. Set false for read-only."
  type        = bool
  default     = true
}

variable "snowflake_names" {
  description = "Names of the Snowflake objects."
  type = object({
    external_volume     = optional(string, "ICEBERG_S3_VOL")
    catalog_integration = optional(string, "GLUE_ICEBERG_REST_INT")
    warehouse           = optional(string, "ICEBERG_WH")
    role                = optional(string, "ICEBERG_ENGINEER")
    linked_database     = optional(string, "GLUE_LAKEHOUSE")
    managed_database    = optional(string, "ICEBERG_MANAGED")
    managed_schema      = optional(string, "ANALYTICS")
    share               = optional(string, "ICEBERG_ANALYTICS_SHARE")
  })
  default = {}
}

variable "snowflake_warehouse_size" {
  description = "Size of the Snowflake warehouse."
  type        = string
  default     = "XSMALL"
}

variable "snowflake_warehouse_auto_suspend_seconds" {
  description = "Seconds of inactivity before the warehouse suspends."
  type        = number
  default     = 60
}

variable "snowflake_role_users" {
  description = "Snowflake users to grant the lakehouse role to."
  type        = list(string)
  default     = []
}

variable "snowflake_share_accounts" {
  description = "Consumer accounts (\"ORGNAME.ACCOUNTNAME\") the Iceberg share is shared with. Empty creates the share without consumers."
  type        = list(string)
  default     = []
}

variable "snowflake_catalog_refresh_seconds" {
  description = "How often Snowflake polls Glue for new snapshots of Glue-managed tables."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Glue ETL job, Data Quality and observability
# ---------------------------------------------------------------------------

variable "enable_glue_job" {
  description = "Create the Glue 5.0 Spark job (data quality gate, MERGE, Iceberg maintenance)."
  type        = bool
  default     = true
}

variable "glue_job_worker_type" {
  description = "Worker type for the Glue job."
  type        = string
  default     = "G.1X"
}

variable "glue_job_number_of_workers" {
  description = "Number of workers for the Glue job."
  type        = number
  default     = 2
}

variable "glue_job_schedule" {
  description = "Cron schedule for the Glue job (Glue trigger syntax), or null to run on demand only."
  type        = string
  default     = null
}

variable "dq_fail_job_on_error" {
  description = "Stop the Glue job before the MERGE when any Data Quality rule fails."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the Glue job."
  type        = number
  default     = 30
}

variable "alert_email" {
  description = "Email address subscribed to job-failure and data-quality alerts. Null for no subscription (the SNS topic is still created)."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Consumers: Athena and EMR Serverless
# ---------------------------------------------------------------------------

variable "athena_bytes_scanned_cutoff" {
  description = "Per-query data scan limit for the Athena workgroup, in bytes (default 10 GB)."
  type        = number
  default     = 10737418240
}

variable "enable_emr_serverless" {
  description = "Create an EMR Serverless Spark application. It auto-stops when idle and costs nothing while stopped."
  type        = bool
  default     = false
}

variable "emr_release_label" {
  description = "EMR release for the Serverless application."
  type        = string
  default     = "emr-7.5.0"
}
