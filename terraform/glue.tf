# The Glue database is the Iceberg namespace. Tables are created by the code
# that owns their schema: PyIceberg (ingest/load_sample_data.py), the Glue
# Spark job, or Snowflake through the catalog-linked database.
resource "aws_glue_catalog_database" "lakehouse" {
  name         = var.glue_database_name
  description  = "Apache Iceberg tables for ${var.project}"
  location_uri = "s3://${aws_s3_bucket.lakehouse.bucket}/${local.warehouse_prefix}/${var.glue_database_name}.db"
}
