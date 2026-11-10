variable "project" {
  description = "Short name used to prefix every resource."
  type        = string
  default     = "iceberg-lakehouse"
}

variable "aws_region" {
  description = "AWS region for S3, Glue and IAM. Should match your Snowflake account region to avoid egress costs."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Name of the S3 bucket that holds Iceberg data and metadata. Leave null to derive one from project + account id + region."
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

# ---------------------------------------------------------------------------
# Snowflake trust (phase 2)
#
# Leave these empty on the first apply. After creating the external volume and
# catalog integration in Snowflake, run `DESC EXTERNAL VOLUME` /
# `DESC CATALOG INTEGRATION` (or `snowflake/setup_snowflake.py bootstrap`,
# which writes snowflake.auto.tfvars.json for you) and apply again.
# ---------------------------------------------------------------------------

variable "snowflake_iam_user_arns" {
  description = "STORAGE_AWS_IAM_USER_ARN / API_AWS_IAM_USER_ARN values reported by Snowflake. Usually one ARN per Snowflake account."
  type        = list(string)
  default     = []
}

variable "snowflake_external_ids" {
  description = "STORAGE_AWS_EXTERNAL_ID (external volume) and API_AWS_EXTERNAL_ID (catalog integration) values reported by Snowflake."
  type        = list(string)
  default     = []
}

variable "allow_snowflake_writes" {
  description = "Let Snowflake write to S3 and Glue so it can INSERT/UPDATE/CREATE Glue-managed Iceberg tables. Set false for read-only."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Optional Glue Spark ETL job
# ---------------------------------------------------------------------------

variable "enable_glue_job" {
  description = "Create a sample AWS Glue 5.0 Spark job that maintains Iceberg tables in the Glue catalog."
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

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}
