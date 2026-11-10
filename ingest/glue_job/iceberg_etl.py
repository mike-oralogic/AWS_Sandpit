"""AWS Glue 5.0 Spark job: maintain Iceberg tables in the Glue catalog.

Deployed by terraform/glue_job.tf. Spark is configured (via --conf) with an
Iceberg catalog named `glue_catalog` backed by the Glue Data Catalog.

Steps:
  1. Create <db>.orders_enriched (Iceberg v2, partitioned by day) if missing.
  2. MERGE the last day's orders joined to customers into it (idempotent upsert).
  3. Iceberg maintenance: compact small files, expire old snapshots.
"""

import sys
from datetime import datetime, timedelta, timezone

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext

args = getResolvedOptions(sys.argv, ["JOB_NAME", "DATABASE"])
db = args["DATABASE"]
cat = "glue_catalog"

sc = SparkContext.getOrCreate()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS {cat}.{db}.orders_enriched (
        order_id      BIGINT,
        customer_id   BIGINT,
        customer_name STRING,
        region        STRING,
        amount        DECIMAL(10, 2),
        order_ts      TIMESTAMP_NTZ
    )
    USING iceberg
    PARTITIONED BY (days(order_ts))
    TBLPROPERTIES (
        'format-version' = '2',
        'write.parquet.compression-codec' = 'zstd',
        'write.merge.mode' = 'merge-on-read',
        'write.update.mode' = 'merge-on-read',
        'write.delete.mode' = 'merge-on-read'
    )
    """
)

spark.sql(
    f"""
    MERGE INTO {cat}.{db}.orders_enriched t
    USING (
        SELECT o.order_id, o.customer_id, c.name AS customer_name, o.region, o.amount, o.order_ts
        FROM {cat}.{db}.orders o
        LEFT JOIN {cat}.{db}.customers c ON o.customer_id = c.customer_id
        WHERE o.order_ts >= date_sub(current_date(), 1)
    ) s
    ON t.order_id = s.order_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
    """
)

# Maintenance keeps reads fast for every engine, Snowflake included.
# Procedure arguments must be literals, so compute the cutoff here.
cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).strftime("%Y-%m-%d %H:%M:%S")
for table in ("orders", "orders_enriched"):
    spark.sql(f"CALL {cat}.system.rewrite_data_files(table => '{db}.{table}')")
    spark.sql(
        f"CALL {cat}.system.expire_snapshots(table => '{db}.{table}', "
        f"older_than => TIMESTAMP '{cutoff}', retain_last => 5)"
    )

job.commit()
