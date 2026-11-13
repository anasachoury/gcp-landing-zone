# Landing zone convenience targets.
#
# All targets are local runs against real Google Cloud and use your
# Application Default Credentials:
#
#   gcloud auth application-default login
#
# Required environment variables:
#
#   LZ_ORG_ID          e.g. 123456789012
#   LZ_BILLING_ACCOUNT e.g. 01ABCD-123456-7890EF
#   LZ_PREFIX          e.g. lz
#   LZ_STATE_BUCKET    e.g. lz-tfstate (created by bootstrap/bootstrap.sh)
#
# Usage:
#
#   make plan   STAGE=01-org
#   make apply  STAGE=01-org

STAGES := 01-org 02-networking 03-security 10-factory

TFVARS := -var org_id=$(LZ_ORG_ID) -var billing_account=$(LZ_BILLING_ACCOUNT) \
          -var prefix=$(LZ_PREFIX) -var state_bucket=$(LZ_STATE_BUCKET)
BACKEND := -backend-config=bucket=$(LZ_STATE_BUCKET) \
           -backend-config=prefix=landing-zone/$(STAGE)

.PHONY: help init plan apply fmt check bootstrap-validate catalog-validate

help:
	@echo "Stages: $(STAGES)"
	@echo "  make init  STAGE=<stage>   initialize a stage backend"
	@echo "  make plan  STAGE=<stage>   plan a stage locally"
	@echo "  make apply STAGE=<stage>   apply a stage locally"
	@echo "  make check                 fmt-check + catalog + bootstrap validation"
	@echo "  make fmt                   rewrite Terraform formatting"

init:
	@test -n "$(STAGE)" || (echo "STAGE is required, e.g. make plan STAGE=01-org"; exit 1)
	@test -n "$(LZ_STATE_BUCKET)" || (echo "LZ_STATE_BUCKET is required"; exit 1)
	cd stages/$(STAGE) && terraform init -input=false $(BACKEND)

plan: init
	@test -n "$(LZ_ORG_ID)" || (echo "LZ_ORG_ID is required"; exit 1)
	cd stages/$(STAGE) && terraform plan -input=false $(TFVARS)

apply: init
	@test -n "$(LZ_ORG_ID)" || (echo "LZ_ORG_ID is required"; exit 1)
	cd stages/$(STAGE) && terraform apply -input=false $(TFVARS)

bootstrap-validate:
	cd bootstrap/tf && terraform init -backend=false && terraform validate
	cd bootstrap/tf-gate && terraform init -backend=false && terraform validate

catalog-validate:
	python3 scripts/validate_catalogs.py

fmt:
	terraform fmt -recursive

check:
	terraform fmt -check -recursive
	$(MAKE) catalog-validate
	$(MAKE) bootstrap-validate
	for stage in $(STAGES); do \
		(cd stages/$$stage && terraform init -backend=false && terraform validate) || exit 1; \
	done
