# ---------------------------------------------------------------------------
# Snowflake <-> AWS connection: external volume (S3) + catalog integration
# (AWS Glue Iceberg REST endpoint, SigV4).
#
# Both reference the IAM role by its predictable ARN and use an external ID
# generated here, so they can be created before the role exists. The role's
# trust policy (iam.tf) then reads Snowflake's IAM user ARN back from them.
# ---------------------------------------------------------------------------

locals {
  sf = var.snowflake_names
}

resource "random_uuid" "snowflake_external_id" {}

resource "snowflake_external_volume" "s3" {
  name         = local.sf.external_volume
  allow_writes = "true"
  comment      = "Iceberg data in s3://${aws_s3_bucket.lakehouse.bucket}"

  storage_location {
    storage_location_name   = "s3-${var.aws_region}"
    storage_provider        = "S3"
    storage_base_url        = "s3://${aws_s3_bucket.lakehouse.bucket}/"
    storage_aws_role_arn    = local.snowflake_role_arn
    storage_aws_external_id = random_uuid.snowflake_external_id.result
    encryption_type         = "AWS_SSE_KMS"
    encryption_kms_key_id   = aws_kms_key.lakehouse.arn
  }
}

resource "snowflake_catalog_integration_iceberg_rest" "glue" {
  name                     = local.sf.catalog_integration
  enabled                  = true
  catalog_namespace        = aws_glue_catalog_database.lakehouse.name
  refresh_interval_seconds = var.snowflake_catalog_refresh_seconds
  comment                  = "AWS Glue Data Catalog (Iceberg REST) in ${local.account_id}/${var.aws_region}"

  rest_config {
    catalog_uri            = "https://glue.${var.aws_region}.amazonaws.com/iceberg"
    catalog_api_type       = "AWS_GLUE"
    catalog_name           = local.account_id
    access_delegation_mode = "EXTERNAL_VOLUME_CREDENTIALS"
  }

  sigv4_rest_authentication {
    sigv4_iam_role       = local.snowflake_role_arn
    sigv4_signing_region = var.aws_region
    sigv4_external_id    = random_uuid.snowflake_external_id.result
  }
}

# The catalog integration resource does not export API_AWS_IAM_USER_ARN, so
# read it with DESC. `execute`/`revert` are no-ops; only `query` matters.
resource "snowflake_execute" "describe_catalog_integration" {
  execute = "SELECT 1"
  revert  = "SELECT 1"
  query   = "DESC CATALOG INTEGRATION \"${snowflake_catalog_integration_iceberg_rest.glue.name}\""
}

locals {
  volume_iam_user_arn = snowflake_external_volume.s3.describe_output[0].storage_locations[0].s3_storage_location[0].storage_aws_iam_user_arn

  catalog_iam_user_arns = [
    for row in snowflake_execute.describe_catalog_integration.query_results :
    lookup(row, "property_value", lookup(row, "PROPERTY_VALUE", ""))
    if upper(lookup(row, "property", lookup(row, "PROPERTY", ""))) == "API_AWS_IAM_USER_ARN"
  ]

  # Snowflake normally uses one IAM user per account, so this is usually a
  # single ARN; distinct() keeps the trust policy clean either way.
  snowflake_iam_user_arns = distinct(compact(concat([local.volume_iam_user_arn], local.catalog_iam_user_arns)))
}
