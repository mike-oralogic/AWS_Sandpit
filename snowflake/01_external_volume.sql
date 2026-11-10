-- External volume: gives Snowflake read/write access to the Iceberg S3 bucket.
-- The double-brace placeholders are filled by setup_snowflake.py from `terraform output`,
-- or replace them by hand. Requires ACCOUNTADMIN (or CREATE EXTERNAL VOLUME).
USE ROLE ACCOUNTADMIN;

CREATE EXTERNAL VOLUME IF NOT EXISTS {{external_volume}}
  STORAGE_LOCATIONS = (
    (
      NAME = 's3-{{aws_region}}'
      STORAGE_PROVIDER = 'S3'
      STORAGE_BASE_URL = '{{external_volume_base_url}}'
      STORAGE_AWS_ROLE_ARN = '{{snowflake_role_arn}}'
      ENCRYPTION = (TYPE = 'AWS_SSE_KMS' KMS_KEY_ID = '{{kms_key_arn}}')
    )
  )
  ALLOW_WRITES = TRUE;

-- STORAGE_LOCATION_1 contains STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID.
DESC EXTERNAL VOLUME {{external_volume}};
