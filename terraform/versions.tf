terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
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

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
