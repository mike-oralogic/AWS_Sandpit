-- Catalog integration against the AWS Glue Iceberg REST endpoint, signed with
-- SigV4 by assuming the Terraform-managed role. Supports reads and writes to
-- Glue-managed Iceberg tables.
USE ROLE ACCOUNTADMIN;

CREATE CATALOG INTEGRATION IF NOT EXISTS {{catalog_integration}}
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT = ICEBERG
  CATALOG_NAMESPACE = '{{glue_database}}'
  REST_CONFIG = (
    CATALOG_URI = '{{glue_iceberg_rest_uri}}'
    CATALOG_API_TYPE = AWS_GLUE
    CATALOG_NAME = '{{aws_account_id}}'
  )
  REST_AUTHENTICATION = (
    TYPE = SIGV4
    SIGV4_IAM_ROLE = '{{snowflake_role_arn}}'
    SIGV4_SIGNING_REGION = '{{aws_region}}'
  )
  ENABLED = TRUE;

-- API_AWS_IAM_USER_ARN and API_AWS_EXTERNAL_ID go into the IAM trust policy.
DESC CATALOG INTEGRATION {{catalog_integration}};
