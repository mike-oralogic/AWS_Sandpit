-- Removes the Snowflake objects. Leaves S3 data and Glue tables alone
-- (dropping a catalog-linked database does not drop the remote tables).
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS {{managed_database}};
DROP DATABASE IF EXISTS {{linked_database}};
DROP CATALOG INTEGRATION IF EXISTS {{catalog_integration}};
DROP EXTERNAL VOLUME IF EXISTS {{external_volume}};
DROP ROLE IF EXISTS {{snowflake_role}};
