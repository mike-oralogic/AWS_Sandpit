"""EMR Serverless Spark job: read-only report over the Glue Iceberg tables.

Submitted with the command in `terraform output emr_start_job_run_command`.
Argument 1: Glue database name (default "lakehouse").
"""

import sys

from pyspark.sql import SparkSession

db = sys.argv[1] if len(sys.argv) > 1 else "lakehouse"
cat = "glue_catalog"

spark = SparkSession.builder.appName("iceberg-report").getOrCreate()

print(f"== Tables in {cat}.{db}")
spark.sql(f"SHOW TABLES IN {cat}.{db}").show(truncate=False)

print("== Revenue by region (current snapshot)")
spark.sql(
    f"""
    SELECT region, COUNT(*) AS orders, SUM(amount) AS revenue
    FROM {cat}.{db}.orders
    GROUP BY region
    ORDER BY revenue DESC
    """
).show(truncate=False)

print("== Snapshot history of orders")
spark.sql(
    f"SELECT committed_at, snapshot_id, operation FROM {cat}.{db}.orders.snapshots ORDER BY committed_at DESC"
).show(20, truncate=False)

print("== Partition sizes of orders")
spark.sql(
    f"SELECT partition, record_count, file_count FROM {cat}.{db}.orders.partitions ORDER BY partition"
).show(40, truncate=False)

spark.stop()
