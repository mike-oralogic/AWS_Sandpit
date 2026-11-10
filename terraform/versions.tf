terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.20, < 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      Project   = var.project
      ManagedBy = "terraform"
    })
  }
}

# Authentication comes from the environment or ~/.snowflake/config, e.g.
#   SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME, SNOWFLAKE_USER,
#   SNOWFLAKE_PRIVATE_KEY (or SNOWFLAKE_PASSWORD / SNOWFLAKE_AUTHENTICATOR),
# or SNOWFLAKE_PROFILE pointing at a profile in ~/.snowflake/config.
provider "snowflake" {
  role = var.snowflake_admin_role

  preview_features_enabled = [
    "snowflake_iceberg_table_resource",
    "snowflake_share_resource",
  ]
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
