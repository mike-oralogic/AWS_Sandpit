-- Example workload once ingest/load_sample_data.py has run.
USE ROLE {{snowflake_role}};
USE WAREHOUSE {{warehouse}};

-- Glue-managed tables appear in the linked database. Names created outside
-- Snowflake are lowercase, so quote them.
SHOW ICEBERG TABLES IN DATABASE {{linked_database}};

SELECT region, COUNT(*) AS orders, SUM(amount) AS revenue
FROM {{linked_database}}."{{glue_database}}"."orders"
GROUP BY region
ORDER BY revenue DESC;

-- Write back to the Glue-managed table from Snowflake.
INSERT INTO {{linked_database}}."{{glue_database}}"."orders"
  (order_id, customer_id, region, amount, order_ts)
VALUES (900001, 42, 'EMEA', 199.99, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(6));

-- Roll Glue data up into the Snowflake-managed Iceberg table.
INSERT OVERWRITE INTO {{managed_database}}.ANALYTICS.DAILY_REVENUE
SELECT order_ts::DATE, region, COUNT(*), SUM(amount)
FROM {{linked_database}}."{{glue_database}}"."orders"
GROUP BY 1, 2;

SELECT * FROM {{managed_database}}.ANALYTICS.DAILY_REVENUE
ORDER BY order_date DESC, region
LIMIT 20;
