# ---------------------------------------------------------------------------
# AWS Glue Data Quality rulesets (DQDL). The Glue job evaluates them against
# the Iceberg tables before it merges anything, publishes the results to the
# Glue Data Quality console, and emits CloudWatch metrics that
# observability.tf alarms on.
#
# The rulesets carry no target_table because the tables are created by the
# loader/job after this apply, not by Terraform.
# ---------------------------------------------------------------------------

locals {
  dq_rulesets = {
    orders    = <<-DQDL
      Rules = [
        RowCount > 0,
        IsComplete "order_id",
        IsUnique "order_id",
        IsComplete "customer_id",
        IsComplete "order_ts",
        ColumnValues "region" in ["AMER", "EMEA", "APAC", "LATAM"],
        ColumnValues "amount" between 0 and 100000
      ]
    DQDL
    customers = <<-DQDL
      Rules = [
        RowCount > 0,
        IsComplete "customer_id",
        IsUnique "customer_id",
        IsComplete "name",
        ColumnValues "region" in ["AMER", "EMEA", "APAC", "LATAM"]
      ]
    DQDL
  }
}

resource "aws_glue_data_quality_ruleset" "lakehouse" {
  for_each = local.dq_rulesets

  name        = "${var.project}-${each.key}"
  description = "Data quality rules for ${var.glue_database_name}.${each.key}"
  ruleset     = each.value
}
