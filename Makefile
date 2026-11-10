# End-to-end build of the Iceberg lakehouse: AWS (S3 + Glue + IAM) <-> Snowflake.
# Run `make help` for the steps.
TF     := terraform -chdir=terraform
PY     := .venv/bin/python
REGION  = $(shell $(TF) output -raw aws_region)
GLUEDB  = $(shell $(TF) output -raw glue_database)
JOB     = $(shell $(TF) output -raw glue_job_name)

.PHONY: help all venv aws snowflake trust verify load objects queries glue-job destroy

help:
	@echo "make venv       install Python deps into .venv"
	@echo "make aws        phase 1: S3 bucket, KMS, Glue database, IAM roles, Glue job"
	@echo "make snowflake  create external volume + catalog integration, capture trust values"
	@echo "make trust      phase 2: apply Snowflake's IAM user + external IDs to the role"
	@echo "make verify     Snowflake checks it can assume the role and reach Glue"
	@echo "make load       create Glue Iceberg tables and load sample data (PyIceberg)"
	@echo "make objects    catalog-linked database + Snowflake-managed Iceberg table"
	@echo "make queries    example reads/writes from Snowflake"
	@echo "make glue-job   run the Glue Spark Iceberg job"
	@echo "make all        venv aws snowflake trust verify load objects queries"
	@echo "make destroy    drop Snowflake objects, then terraform destroy"

all: venv aws snowflake trust verify load objects queries

venv:
	python3 -m venv .venv
	.venv/bin/pip install -q -r snowflake/requirements.txt -r ingest/requirements.txt

aws:
	$(TF) init -upgrade
	$(TF) apply

snowflake:
	$(PY) snowflake/setup_snowflake.py bootstrap

trust:
	$(TF) apply

verify:
	$(PY) snowflake/setup_snowflake.py verify

load:
	$(PY) ingest/load_sample_data.py --region $(REGION) --database $(GLUEDB)

objects:
	$(PY) snowflake/setup_snowflake.py objects

queries:
	$(PY) snowflake/setup_snowflake.py queries

glue-job:
	aws glue start-job-run --region $(REGION) --job-name $(JOB)

destroy:
	$(PY) snowflake/setup_snowflake.py teardown
	$(TF) destroy
