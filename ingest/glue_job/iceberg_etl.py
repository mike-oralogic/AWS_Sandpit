"""AWS Glue 5.0 Spark job for the Iceberg lakehouse.

Deployed by terraform/glue_job.tf. Spark is configured (via --conf) with an
Iceberg catalog named `glue_catalog` backed by the Glue Data Catalog.

Steps:
  1. Data Quality gate: evaluate the Glue Data Quality rulesets against the
     source Iceberg tables, publish results (Glue console + CloudWatch
     metrics) and, if --DQ_FAIL_ON_ERROR is true, stop before writing.
  2. Create <db>.orders_enriched (Iceberg v2, partitioned by day) if missing
     and MERGE the last day's orders joined to customers into it.
  3. Iceberg maintenance: compact small files, expire old snapshots.
"""

import json
import sys
from datetime import datetime, timedelta, timezone

import boto3
from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from awsgluedq.transforms import EvaluateDataQuality
from pyspark.context import SparkContext

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "DATABASE", "DQ_RULESETS", "DQ_FAIL_ON_ERROR", "DQ_METRIC_NAMESPACE"],
)
db = args["DATABASE"]
cat = "glue_catalog"
rulesets = json.loads(args["DQ_RULESETS"])  # {"orders": "<ruleset name>", ...}
fail_on_error = args["DQ_FAIL_ON_ERROR"].lower() == "true"

sc = SparkContext.getOrCreate()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
logger = glue_context.get_logger()
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

glue = boto3.client("glue")
cloudwatch = boto3.client("cloudwatch")


# ---------------------------------------------------------------------------
# 1. Data Quality gate
# ---------------------------------------------------------------------------
def evaluate(table: str, ruleset_name: str) -> list[dict]:
    ruleset = glue.get_data_quality_ruleset(Name=ruleset_name)["Ruleset"]
    frame = DynamicFrame.fromDF(spark.table(f"{cat}.{db}.{table}"), glue_context, table)
    outcomes = EvaluateDataQuality.apply(
        frame=frame,
        ruleset=ruleset,
        publishing_options={
            "dataQualityEvaluationContext": f"{db}.{table}",
            "enableDataQualityCloudWatchMetrics": True,
            "enableDataQualityResultsPublishing": True,
        },
    )
    rows = [r.asDict() for r in outcomes.toDF().collect()]
    passed = sum(1 for r in rows if r["Outcome"] == "Passed")
    failed = len(rows) - passed
    cloudwatch.put_metric_data(
        Namespace=args["DQ_METRIC_NAMESPACE"],
        MetricData=[
            {"MetricName": "RulesPassed", "Dimensions": [{"Name": "Table", "Value": table}], "Value": passed},
            {"MetricName": "RulesFailed", "Dimensions": [{"Name": "Table", "Value": table}], "Value": failed},
        ],
    )
    for r in rows:
        if r["Outcome"] != "Passed":
            logger.error(f"DQ rule failed on {db}.{table}: {r['Rule']} -> {r.get('FailureReason')}")
    logger.info(f"DQ {db}.{table}: {passed} passed, {failed} failed")
    return [r for r in rows if r["Outcome"] != "Passed"]


failures = {table: evaluate(table, name) for table, name in rulesets.items()}
failed_tables = [t for t, f in failures.items() if f]
if failed_tables and fail_on_error:
    raise RuntimeError(f"Data Quality gate failed for: {', '.join(failed_tables)}")

# ---------------------------------------------------------------------------
# 2. Transform: MERGE into orders_enriched
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 3. Maintenance keeps reads fast for every engine, Snowflake included.
#    Procedure arguments must be literals, so compute the cutoff here.
# ---------------------------------------------------------------------------
cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).strftime("%Y-%m-%d %H:%M:%S")
for table in ("orders", "orders_enriched"):
    spark.sql(f"CALL {cat}.system.rewrite_data_files(table => '{db}.{table}')")
    spark.sql(
        f"CALL {cat}.system.expire_snapshots(table => '{db}.{table}', "
        f"older_than => TIMESTAMP '{cutoff}', retain_last => 5)"
    )

job.commit()
