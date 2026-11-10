-- Run after `terraform apply` has written Snowflake's IAM user and external
-- IDs into the role's trust policy.
USE ROLE ACCOUNTADMIN;

SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('{{external_volume}}');
SELECT SYSTEM$VERIFY_CATALOG_INTEGRATION('{{catalog_integration}}');

-- Should list the Glue database as a namespace.
SELECT SYSTEM$LIST_NAMESPACES_FROM_CATALOG('{{catalog_integration}}');
