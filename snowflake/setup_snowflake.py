#!/usr/bin/env python3
"""Drive the Snowflake side of the Iceberg lakehouse.

Reads `terraform output -json`, fills the {{placeholders}} in the numbered SQL
files and runs them. `bootstrap` also closes the AWS <-> Snowflake trust loop
by writing Snowflake's IAM user ARN and external IDs to
../terraform/snowflake.auto.tfvars.json.

Commands:
  render <file.sql>  print a SQL file with placeholders filled (no connection)
  bootstrap          01 + 02: external volume + catalog integration, then
                     write snowflake.auto.tfvars.json for terraform phase 2
  verify             03: check Snowflake can assume the role and reach Glue
  objects            04: role, catalog-linked database, managed Iceberg table
  queries            05: example reads and writes
  teardown           99: drop the Snowflake objects

Connection: set SNOWFLAKE_CONNECTION to a name in ~/.snowflake/connections.toml,
or SNOWFLAKE_ACCOUNT + SNOWFLAKE_USER and one of SNOWFLAKE_PASSWORD,
SNOWFLAKE_PRIVATE_KEY_FILE or SNOWFLAKE_AUTHENTICATOR (e.g. externalbrowser).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TERRAFORM_DIR = HERE.parent / "terraform"
TFVARS_OUT = TERRAFORM_DIR / "snowflake.auto.tfvars.json"

# Snowflake object names; override with environment variables.
SNOWFLAKE_NAMES = {
    "external_volume": os.getenv("ICEBERG_EXTERNAL_VOLUME", "ICEBERG_S3_VOL"),
    "catalog_integration": os.getenv("ICEBERG_CATALOG_INTEGRATION", "GLUE_ICEBERG_REST_INT"),
    "linked_database": os.getenv("ICEBERG_LINKED_DATABASE", "GLUE_LAKEHOUSE"),
    "managed_database": os.getenv("ICEBERG_MANAGED_DATABASE", "ICEBERG_MANAGED"),
    "snowflake_role": os.getenv("ICEBERG_ROLE", "ICEBERG_ENGINEER"),
    "warehouse": os.getenv("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH"),
}

TERRAFORM_KEYS = [
    "aws_account_id",
    "aws_region",
    "external_volume_base_url",
    "glue_database",
    "glue_iceberg_rest_uri",
    "kms_key_arn",
    "snowflake_role_arn",
]

SQL_FILES = {
    "bootstrap": ["01_external_volume.sql", "02_catalog_integration.sql"],
    "verify": ["03_verify.sql"],
    "objects": ["04_databases_and_tables.sql"],
    "queries": ["05_queries.sql"],
    "teardown": ["99_teardown.sql"],
}


def terraform_outputs() -> dict[str, str]:
    try:
        raw = subprocess.run(
            ["terraform", f"-chdir={TERRAFORM_DIR}", "output", "-json"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.exit(f"Could not read terraform outputs (run `terraform apply` first): {exc}")
    outputs = {k: v["value"] for k, v in json.loads(raw).items()}
    missing = [k for k in TERRAFORM_KEYS if outputs.get(k) in (None, "")]
    if missing:
        sys.exit(f"terraform outputs missing: {', '.join(missing)}")
    return {k: str(outputs[k]) for k in TERRAFORM_KEYS}


def render(sql_file: str, values: dict[str, str]) -> str:
    text = (HERE / sql_file).read_text()

    def sub(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in values:
            sys.exit(f"{sql_file}: no value for placeholder {key}")
        return values[key]

    return re.sub(r"\{\{(\w+)\}\}", sub, text)


def connect():
    import snowflake.connector

    if name := os.getenv("SNOWFLAKE_CONNECTION"):
        return snowflake.connector.connect(connection_name=name)

    params = {
        "account": os.getenv("SNOWFLAKE_ACCOUNT"),
        "user": os.getenv("SNOWFLAKE_USER"),
    }
    if not all(params.values()):
        sys.exit("Set SNOWFLAKE_CONNECTION, or SNOWFLAKE_ACCOUNT and SNOWFLAKE_USER.")
    optional = {
        "password": "SNOWFLAKE_PASSWORD",
        "private_key_file": "SNOWFLAKE_PRIVATE_KEY_FILE",
        "authenticator": "SNOWFLAKE_AUTHENTICATOR",
    }
    params.update({k: os.environ[v] for k, v in optional.items() if os.getenv(v)})
    return snowflake.connector.connect(**params)


def run_script(conn, sql: str) -> None:
    """Execute a multi-statement script, echoing each statement and its rows."""
    for cur in conn.execute_string(sql, remove_comments=True):
        print(f"\n>>> {cur.query.strip()}")
        if cur.description:
            cols = [d[0] for d in cur.description]
            for row in cur.fetchall():
                print("   ", dict(zip(cols, row)))


def describe(conn, sql: str) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(sql)
        cols = [d[0].lower() for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]


def snowflake_trust_values(conn) -> tuple[list[str], list[str]]:
    arns: set[str] = set()
    ext_ids: set[str] = set()

    # External volume: each STORAGE_LOCATION_n property holds a JSON document.
    for row in describe(conn, f"DESC EXTERNAL VOLUME {SNOWFLAKE_NAMES['external_volume']}"):
        if str(row.get("property", "")).startswith("STORAGE_LOCATION_"):
            loc = json.loads(row["property_value"])
            arns.add(loc["STORAGE_AWS_IAM_USER_ARN"])
            ext_ids.add(loc["STORAGE_AWS_EXTERNAL_ID"])

    # Catalog integration: flat properties.
    for row in describe(conn, f"DESC CATALOG INTEGRATION {SNOWFLAKE_NAMES['catalog_integration']}"):
        if row.get("property") == "API_AWS_IAM_USER_ARN":
            arns.add(row["property_value"])
        elif row.get("property") == "API_AWS_EXTERNAL_ID":
            ext_ids.add(row["property_value"])

    if not arns or not ext_ids:
        sys.exit("Could not find Snowflake's IAM user ARN / external IDs in the DESC output.")
    return sorted(arns), sorted(ext_ids)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["render", *SQL_FILES])
    parser.add_argument("sql_file", nargs="?", help="SQL file for `render`")
    args = parser.parse_args()

    values = {**terraform_outputs(), **SNOWFLAKE_NAMES}

    if args.command == "render":
        if not args.sql_file:
            parser.error("render needs a SQL file")
        print(render(args.sql_file, values))
        return

    conn = connect()
    try:
        for sql_file in SQL_FILES[args.command]:
            print(f"\n=== {sql_file} ===")
            run_script(conn, render(sql_file, values))

        if args.command == "bootstrap":
            arns, ext_ids = snowflake_trust_values(conn)
            TFVARS_OUT.write_text(
                json.dumps({"snowflake_iam_user_arns": arns, "snowflake_external_ids": ext_ids}, indent=2) + "\n"
            )
            print(f"\nWrote {TFVARS_OUT}.\nNext: `terraform apply` again (make trust), then `make verify`.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
