-- Example Snowflake workload. Terraform creates every object used here
-- (default names; adjust if you changed var.snowflake_names). Run after
-- `make load` has put data into the Glue tables.
USE ROLE ICEBERG_ENGINEER;
USE WAREHOUSE ICEBERG_WH;

-- Check Snowflake can reach S3 and Glue through the IAM role.
SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('ICEBERG_S3_VOL');
SELECT SYSTEM$VERIFY_CATALOG_INTEGRATION('GLUE_ICEBERG_REST_INT');

-- Glue-managed tables appear in the catalog-linked database. Names created
-- outside Snowflake are lowercase, so quote them.
SHOW ICEBERG TABLES IN DATABASE GLUE_LAKEHOUSE;

SELECT region, COUNT(*) AS orders, SUM(amount) AS revenue
FROM GLUE_LAKEHOUSE."lakehouse"."orders"
GROUP BY region
ORDER BY revenue DESC;

-- Write back to the Glue-managed table; Athena/EMR/Glue see the new snapshot.
INSERT INTO GLUE_LAKEHOUSE."lakehouse"."orders"
  (order_id, customer_id, region, amount, order_ts)
VALUES (900001, 42, 'EMEA', 199.99, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(6));

-- Roll up into the Snowflake-managed Iceberg table (shared via ICEBERG_ANALYTICS_SHARE).
INSERT OVERWRITE INTO ICEBERG_MANAGED.ANALYTICS.DAILY_REVENUE
SELECT order_ts::DATE, region, COUNT(*), SUM(amount)
FROM GLUE_LAKEHOUSE."lakehouse"."orders"
GROUP BY 1, 2;

SELECT * FROM ICEBERG_MANAGED.ANALYTICS.DAILY_REVENUE
ORDER BY order_date DESC, region
LIMIT 20;
