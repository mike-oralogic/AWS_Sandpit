-- Objects that expose the Iceberg tables in Snowflake.
USE ROLE ACCOUNTADMIN;

-- Role for the people who use the lakehouse.
CREATE ROLE IF NOT EXISTS {{snowflake_role}};
GRANT USAGE ON EXTERNAL VOLUME {{external_volume}} TO ROLE {{snowflake_role}};
GRANT USAGE ON INTEGRATION {{catalog_integration}} TO ROLE {{snowflake_role}};
GRANT USAGE ON WAREHOUSE {{warehouse}} TO ROLE {{snowflake_role}};
GRANT ROLE {{snowflake_role}} TO ROLE SYSADMIN;

-- 1) Catalog-linked database: every Iceberg table in the Glue namespace shows
--    up automatically and stays in sync with Glue. Snowflake can also INSERT,
--    UPDATE, DELETE and CREATE ICEBERG TABLE here; commits go to Glue, so
--    Spark, Athena and PyIceberg see the same snapshots.
CREATE DATABASE IF NOT EXISTS {{linked_database}}
  LINKED_CATALOG = (
    CATALOG = '{{catalog_integration}}',
    ALLOWED_NAMESPACES = ('{{glue_database}}')
  )
  EXTERNAL_VOLUME = '{{external_volume}}';

GRANT OWNERSHIP ON DATABASE {{linked_database}} TO ROLE {{snowflake_role}} COPY CURRENT GRANTS;

-- 2) Snowflake-managed Iceberg tables: Snowflake is the catalog, but the data
--    still lands as open Iceberg/Parquet in your bucket (under snowflake_managed/).
CREATE DATABASE IF NOT EXISTS {{managed_database}};
CREATE SCHEMA IF NOT EXISTS {{managed_database}}.ANALYTICS;
GRANT OWNERSHIP ON SCHEMA {{managed_database}}.ANALYTICS TO ROLE {{snowflake_role}} COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE {{managed_database}} TO ROLE {{snowflake_role}} COPY CURRENT GRANTS;

USE ROLE {{snowflake_role}};
USE WAREHOUSE {{warehouse}};

CREATE ICEBERG TABLE IF NOT EXISTS {{managed_database}}.ANALYTICS.DAILY_REVENUE (
    order_date   DATE,
    region       STRING,
    order_count  NUMBER(38, 0),
    revenue      NUMBER(18, 2)
)
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = '{{external_volume}}'
  BASE_LOCATION = 'snowflake_managed/analytics/daily_revenue';
