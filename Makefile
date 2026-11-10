# Iceberg lakehouse: AWS (S3, Glue, Athena, EMR) + Snowflake, one Terraform apply.
TF     := terraform -chdir=terraform
PY     := .venv/bin/python
REGION  = $(shell $(TF) output -raw aws_region)
GLUEDB  = $(shell $(TF) output -raw glue_database)
JOB     = $(shell $(TF) output -raw glue_job_name)

.PHONY: help all venv init plan apply load glue-job emr-job destroy

help:
	@echo "make venv      install the PyIceberg loader into .venv"
	@echo "make plan      terraform init + plan"
	@echo "make apply     create everything in AWS and Snowflake"
	@echo "make load      create the Glue Iceberg tables and load sample data"
	@echo "make glue-job  run the Glue job (Data Quality gate, MERGE, maintenance)"
	@echo "make emr-job   run the Iceberg report on EMR Serverless (enable_emr_serverless = true)"
	@echo "make all       venv apply load glue-job"
	@echo "make destroy   remove everything"

all: venv apply load glue-job

venv:
	python3 -m venv .venv
	.venv/bin/pip install -q -r ingest/requirements.txt

init:
	$(TF) init -upgrade

plan: init
	$(TF) plan

apply: init
	$(TF) apply

load:
	$(PY) ingest/load_sample_data.py --region $(REGION) --database $(GLUEDB)

glue-job:
	aws glue start-job-run --region $(REGION) --job-name $(JOB)

emr-job:
	$(TF) output -raw emr_start_job_run_command | sh

destroy:
	$(TF) destroy
