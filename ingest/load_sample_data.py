#!/usr/bin/env python3
"""Create Iceberg tables in the AWS Glue catalog and load sample data with PyIceberg.

Tables:
  <db>.customers  unpartitioned, overwritten each run
  <db>.orders     partitioned by day(order_ts), appended each run (new snapshot)

Uses your normal AWS credentials (env vars, profile, SSO). Example:
  python load_sample_data.py --region us-east-1 --database lakehouse --orders 5000
"""

from __future__ import annotations

import argparse
import random
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pyarrow as pa
import pyarrow.compute as pc
from pyiceberg.catalog import load_catalog
from pyiceberg.exceptions import NamespaceAlreadyExistsError
from pyiceberg.partitioning import PartitionField, PartitionSpec
from pyiceberg.schema import Schema
from pyiceberg.transforms import DayTransform
from pyiceberg.types import DecimalType, LongType, NestedField, StringType, TimestampType

REGIONS = ["AMER", "EMEA", "APAC", "LATAM"]

CUSTOMERS_SCHEMA = Schema(
    NestedField(1, "customer_id", LongType(), required=False),
    NestedField(2, "name", StringType(), required=False),
    NestedField(3, "region", StringType(), required=False),
    NestedField(4, "signup_ts", TimestampType(), required=False),
)

ORDERS_SCHEMA = Schema(
    NestedField(1, "order_id", LongType(), required=False),
    NestedField(2, "customer_id", LongType(), required=False),
    NestedField(3, "region", StringType(), required=False),
    NestedField(4, "amount", DecimalType(10, 2), required=False),
    NestedField(5, "order_ts", TimestampType(), required=False),
)

ORDERS_SPEC = PartitionSpec(
    PartitionField(source_id=5, field_id=1000, transform=DayTransform(), name="order_day")
)

TABLE_PROPERTIES = {
    "format-version": "2",
    "write.parquet.compression-codec": "zstd",
}


def build_customers(n: int, now: datetime) -> pa.Table:
    rng = random.Random(7)
    return pa.table(
        {
            "customer_id": pa.array(range(1, n + 1), pa.int64()),
            "name": [f"Customer {i}" for i in range(1, n + 1)],
            "region": [rng.choice(REGIONS) for _ in range(n)],
            "signup_ts": pa.array(
                [now - timedelta(days=rng.randint(30, 900)) for _ in range(n)], pa.timestamp("us")
            ),
        }
    )


def build_orders(n: int, customers: int, start_id: int, now: datetime) -> pa.Table:
    rng = random.Random(start_id)
    return pa.table(
        {
            "order_id": pa.array(range(start_id, start_id + n), pa.int64()),
            "customer_id": pa.array([rng.randint(1, customers) for _ in range(n)], pa.int64()),
            "region": [rng.choice(REGIONS) for _ in range(n)],
            "amount": pa.array(
                [Decimal(rng.randint(500, 50000)) / 100 for _ in range(n)], pa.decimal128(10, 2)
            ),
            "order_ts": pa.array(
                [now - timedelta(minutes=rng.randint(0, 60 * 24 * 30)) for _ in range(n)],
                pa.timestamp("us"),
            ),
        }
    )


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--region", required=True)
    p.add_argument("--database", default="lakehouse")
    p.add_argument("--customers", type=int, default=500)
    p.add_argument("--orders", type=int, default=5000)
    p.add_argument("--profile", help="AWS profile name")
    args = p.parse_args()

    props = {"type": "glue", "glue.region": args.region, "s3.region": args.region}
    if args.profile:
        props["glue.profile-name"] = args.profile
        props["s3.profile-name"] = args.profile
    catalog = load_catalog("glue", **props)

    try:
        catalog.create_namespace(args.database)
    except NamespaceAlreadyExistsError:
        pass

    # Zone-less timestamps map to Snowflake TIMESTAMP_NTZ(6).
    now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)

    customers = catalog.create_table_if_not_exists(
        f"{args.database}.customers", schema=CUSTOMERS_SCHEMA, properties=TABLE_PROPERTIES
    )
    customers.overwrite(build_customers(args.customers, now))
    print(f"customers: {customers.scan().count()} rows at {customers.location()}")

    orders = catalog.create_table_if_not_exists(
        f"{args.database}.orders",
        schema=ORDERS_SCHEMA,
        partition_spec=ORDERS_SPEC,
        properties=TABLE_PROPERTIES,
    )
    max_id = pc.max(orders.scan(selected_fields=("order_id",)).to_arrow()["order_id"]).as_py()
    orders.append(build_orders(args.orders, args.customers, (max_id or 0) + 1, now))
    orders.refresh()
    print(f"orders: {orders.scan().count()} rows at {orders.location()}")
    print(f"orders snapshots: {[s.snapshot_id for s in orders.snapshots()]}")


if __name__ == "__main__":
    main()
