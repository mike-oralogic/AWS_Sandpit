# AWS Sandpit — Apache Iceberg lakehouse on S3 + Glue, queried from Snowflake

A working Apache Iceberg setup:

- **Amazon S3** holds the Iceberg data and metadata (Parquet + JSON/Avro), encrypted with KMS.
- **AWS Glue Data Catalog** is the Iceberg catalog. Tables are written by PyIceberg and by a Glue Spark job.
- **Snowflake** reads *and writes* the same tables through Glue's Iceberg REST endpoint, and can also
  hold its own Snowflake-managed Iceberg tables in the same bucket.

```
PyIceberg / Glue Spark ──writes──▶ Glue Data Catalog (db: lakehouse) ──points to──▶ S3 bucket (SSE-KMS)
                                          ▲                                              ▲
                                Iceberg REST + SigV4                               external volume
                                          │                                              │
                                          └────── IAM role <project>-snowflake ──────────┘
                                                              ▲
                                                          Snowflake
                                        • GLUE_LAKEHOUSE  — catalog-linked DB (Glue tables, read/write)
                                        • ICEBERG_MANAGED — Snowflake-managed Iceberg tables in the same bucket
```

## Layout

| Path | What it is |
|------|------------|
| `terraform/` | S3 bucket, KMS key, Glue database, IAM role for Snowflake, optional Glue 5.0 Spark job |
| `snowflake/0*.sql` | External volume, catalog integration, verification, databases/tables, example queries |
| `snowflake/setup_snowflake.py` | Fills the SQL from `terraform output`, runs it, and writes Snowflake's trust values back for Terraform |
| `ingest/load_sample_data.py` | PyIceberg: creates `customers` and `orders` (partitioned by day) in Glue and loads sample rows |
| `ingest/glue_job/iceberg_etl.py` | Glue Spark job: `MERGE` into `orders_enriched`, then compaction + snapshot expiry |
| `Makefile` | Runs the whole thing in order |

## Prerequisites

- Terraform ≥ 1.6, Python ≥ 3.10, AWS CLI.
- AWS credentials allowed to create S3, KMS, IAM, Glue resources.
- A Snowflake account **in the same AWS region** (cross-region works but costs egress), and a user
  with `ACCOUNTADMIN` (or rights to create external volumes, integrations and databases) plus a warehouse.
- If your AWS account has Lake Formation enforcing permissions on the Glue catalog (i.e. you removed the
  default `IAMAllowedPrincipals` grants), also grant the `<project>-snowflake` and `<project>-glue-job`
  roles Lake Formation permissions on the `lakehouse` database. Out of the box, IAM permissions are enough.

## Build it

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # set aws_region etc.
```

```bash
export SNOWFLAKE_CONNECTION=my_conn   # a name in ~/.snowflake/connections.toml
```

(or set `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER` and one of `SNOWFLAKE_PASSWORD` /
`SNOWFLAKE_PRIVATE_KEY_FILE` / `SNOWFLAKE_AUTHENTICATOR=externalbrowser`; set `SNOWFLAKE_WAREHOUSE` if
yours isn't `COMPUTE_WH`.)

```bash
make all
```

That runs the steps below; you can also run them one by one.

| Step | Command | What happens |
|------|---------|--------------|
| 1 | `make venv` | Python virtualenv with the Snowflake connector and PyIceberg |
| 2 | `make aws` | **Phase 1** apply: bucket, KMS, Glue DB, IAM role (trust policy is a locked placeholder), Glue job |
| 3 | `make snowflake` | Creates the external volume and Glue REST catalog integration, reads `DESC` output, writes `terraform/snowflake.auto.tfvars.json` |
| 4 | `make trust` | **Phase 2** apply: role now trusts Snowflake's IAM user with both external IDs |
| 5 | `make verify` | `SYSTEM$VERIFY_EXTERNAL_VOLUME`, `SYSTEM$VERIFY_CATALOG_INTEGRATION`, list namespaces |
| 6 | `make load` | PyIceberg creates and fills `lakehouse.customers` and `lakehouse.orders` in Glue |
| 7 | `make objects` | `ICEBERG_ENGINEER` role, catalog-linked database `GLUE_LAKEHOUSE`, managed table `ICEBERG_MANAGED.ANALYTICS.DAILY_REVENUE` |
| 8 | `make queries` | Reads Glue tables, inserts a row back into Glue from Snowflake, rolls up into the managed table |
| — | `make glue-job` | Optional: runs the Glue Spark job (`MERGE` + maintenance) |

Why two Terraform applies? Snowflake only reveals the IAM user and external IDs it will use *after* the
external volume and catalog integration exist, and those need the role ARN first. Phase 1 creates the
role with a trust policy nobody can satisfy; phase 2 swaps in the real values.

To run the SQL by hand instead, print any file with the placeholders filled:

```bash
.venv/bin/python snowflake/setup_snowflake.py render 02_catalog_integration.sql
```

## Things to know

- **Names:** tables created outside Snowflake are lowercase, so quote them in Snowflake:
  `GLUE_LAKEHOUSE."lakehouse"."orders"`.
- **Timestamps:** the sample uses zone-less `timestamp` (Iceberg) → `TIMESTAMP_NTZ(6)` (Snowflake).
- **Read-only Snowflake:** set `allow_snowflake_writes = false` in Terraform and `ALLOW_WRITES = FALSE`
  on the external volume.
- **Maintenance:** Glue-managed tables need compaction and snapshot expiry. The Glue job does it, or
  turn on Glue's automatic table optimizers. Snowflake maintains its own managed tables.
- **Costs:** S3 storage + requests, KMS requests (reduced by S3 Bucket Keys), Glue catalog requests, Glue
  job DPU-hours when run, and Snowflake warehouse credits.

## Tear down

```bash
make destroy
```

This drops the Snowflake objects, then runs `terraform destroy`. The bucket must be empty unless
`force_destroy_bucket = true`. The KMS key is scheduled for deletion after 7 days.
