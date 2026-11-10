# ---------------------------------------------------------------------------
# Snowflake objects on top of the connection (diagram steps 4 and 5):
# warehouse, role, catalog-linked database of Glue Iceberg tables,
# Snowflake-managed Iceberg tables, and a share.
# ---------------------------------------------------------------------------

resource "snowflake_warehouse" "iceberg" {
  name                = local.sf.warehouse
  warehouse_size      = var.snowflake_warehouse_size
  auto_suspend        = var.snowflake_warehouse_auto_suspend_seconds
  auto_resume         = "true"
  initially_suspended = true
  comment             = "Queries over the Iceberg lakehouse"
}

resource "snowflake_account_role" "engineer" {
  name    = local.sf.role
  comment = "Uses the Iceberg lakehouse (Glue-linked and Snowflake-managed tables)"
}

# Keep the role in the standard hierarchy so SYSADMIN/ACCOUNTADMIN can manage
# what it owns.
resource "snowflake_grant_account_role" "engineer_to_sysadmin" {
  role_name        = snowflake_account_role.engineer.name
  parent_role_name = "SYSADMIN"
}

resource "snowflake_grant_account_role" "engineer_to_users" {
  for_each = toset(var.snowflake_role_users)

  role_name = snowflake_account_role.engineer.name
  user_name = each.value
}

resource "snowflake_grant_privileges_to_account_role" "warehouse" {
  account_role_name = snowflake_account_role.engineer.name
  privileges        = ["USAGE", "OPERATE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.iceberg.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "external_volume" {
  account_role_name = snowflake_account_role.engineer.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "EXTERNAL VOLUME"
    object_name = snowflake_external_volume.s3.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "catalog_integration" {
  account_role_name = snowflake_account_role.engineer.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_catalog_integration_iceberg_rest.glue.name
  }
}

# ---------------------------------------------------------------------------
# Catalog-linked database: every Iceberg table in the Glue namespace appears
# automatically and stays in sync. Snowflake can also INSERT/UPDATE/DELETE and
# CREATE ICEBERG TABLE here; commits go to Glue, so Athena, EMR, Glue and
# PyIceberg see the same snapshots.
#
# The provider has no resource for catalog-linked databases yet, hence SQL.
# ---------------------------------------------------------------------------

resource "snowflake_execute" "linked_database" {
  execute = <<-SQL
    CREATE DATABASE "${local.sf.linked_database}"
      LINKED_CATALOG = (
        CATALOG = '${snowflake_catalog_integration_iceberg_rest.glue.name}',
        ALLOWED_NAMESPACES = ('${aws_glue_catalog_database.lakehouse.name}')
      )
      EXTERNAL_VOLUME = '${snowflake_external_volume.s3.name}'
      COMMENT = 'Glue Data Catalog ${aws_glue_catalog_database.lakehouse.name} (managed by Terraform)'
  SQL
  revert  = "DROP DATABASE IF EXISTS \"${local.sf.linked_database}\""
  query   = "SHOW DATABASES LIKE '${local.sf.linked_database}'"

  depends_on = [time_sleep.snowflake_role_propagation]
}

# Owning the database lets the role use and write the tables Snowflake
# discovers in Glue.
resource "snowflake_grant_ownership" "linked_database" {
  account_role_name   = snowflake_account_role.engineer.name
  outbound_privileges = "COPY"
  on {
    object_type = "DATABASE"
    object_name = local.sf.linked_database
  }

  depends_on = [snowflake_execute.linked_database, snowflake_grant_account_role.engineer_to_sysadmin]
}

# ---------------------------------------------------------------------------
# Snowflake-managed Iceberg tables: Snowflake is the catalog, data still lands
# as open Iceberg/Parquet in the same bucket (under snowflake_managed/).
# ---------------------------------------------------------------------------

resource "snowflake_database" "managed" {
  name            = local.sf.managed_database
  comment         = "Snowflake-managed Iceberg tables stored in s3://${aws_s3_bucket.lakehouse.bucket}/snowflake_managed/"
  external_volume = snowflake_external_volume.s3.name
  catalog         = "SNOWFLAKE"
}

resource "snowflake_schema" "managed" {
  database = snowflake_database.managed.name
  name     = local.sf.managed_schema
}

resource "snowflake_iceberg_table" "daily_revenue" {
  database        = snowflake_database.managed.name
  schema          = snowflake_schema.managed.name
  name            = "DAILY_REVENUE"
  catalog         = "SNOWFLAKE"
  external_volume = snowflake_external_volume.s3.name
  base_location   = "snowflake_managed/${lower(local.sf.managed_schema)}/daily_revenue"
  comment         = "Daily order rollup built from the Glue-managed orders table"

  column {
    name = "ORDER_DATE"
    type = "DATE"
  }
  column {
    name = "REGION"
    type = "VARCHAR"
  }
  column {
    name = "ORDER_COUNT"
    type = "NUMBER(38,0)"
  }
  column {
    name = "REVENUE"
    type = "NUMBER(18,2)"
  }

  depends_on = [time_sleep.snowflake_role_propagation]
}

locals {
  daily_revenue_fqn = "\"${snowflake_database.managed.name}\".\"${snowflake_schema.managed.name}\".\"${snowflake_iceberg_table.daily_revenue.name}\""
}

resource "snowflake_grant_privileges_to_account_role" "managed_database" {
  account_role_name = snowflake_account_role.engineer.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.managed.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "managed_schema" {
  account_role_name = snowflake_account_role.engineer.name
  privileges        = ["USAGE", "CREATE ICEBERG TABLE"]
  on_schema {
    schema_name = "\"${snowflake_database.managed.name}\".\"${snowflake_schema.managed.name}\""
  }
}

resource "snowflake_grant_privileges_to_account_role" "daily_revenue" {
  account_role_name = snowflake_account_role.engineer.name
  privileges        = ["SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE"]
  on_schema_object {
    object_type = "ICEBERG TABLE"
    object_name = local.daily_revenue_fqn
  }
}

# ---------------------------------------------------------------------------
# Share the Snowflake-managed Iceberg rollup with other Snowflake accounts.
# Consumers can only be added after the share has a database granted, so the
# accounts are attached in a final step.
# ---------------------------------------------------------------------------

resource "snowflake_share" "iceberg" {
  name    = local.sf.share
  comment = "Iceberg analytics tables from ${local.sf.managed_database}"
}

resource "snowflake_grant_privileges_to_share" "database" {
  to_share    = snowflake_share.iceberg.name
  privileges  = ["USAGE"]
  on_database = snowflake_database.managed.name
}

resource "snowflake_grant_privileges_to_share" "schema" {
  to_share   = snowflake_share.iceberg.name
  privileges = ["USAGE"]
  on_schema  = "\"${snowflake_database.managed.name}\".\"${snowflake_schema.managed.name}\""

  depends_on = [snowflake_grant_privileges_to_share.database]
}

resource "snowflake_grant_privileges_to_share" "daily_revenue" {
  to_share   = snowflake_share.iceberg.name
  privileges = ["SELECT"]
  on_table   = local.daily_revenue_fqn

  depends_on = [snowflake_grant_privileges_to_share.schema]
}

resource "snowflake_execute" "share_accounts" {
  count = length(var.snowflake_share_accounts) > 0 ? 1 : 0

  execute = "ALTER SHARE \"${snowflake_share.iceberg.name}\" ADD ACCOUNTS = ${join(", ", var.snowflake_share_accounts)}"
  revert  = "ALTER SHARE \"${snowflake_share.iceberg.name}\" REMOVE ACCOUNTS = ${join(", ", var.snowflake_share_accounts)}"

  depends_on = [snowflake_grant_privileges_to_share.daily_revenue]
}
