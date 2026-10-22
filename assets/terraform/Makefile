# Thin wrappers so every root is driven the same way.
#   make plan ROOT=live/acme-app/prod
#   make apply ROOT=live/acme-app/prod
#   make lint                      # whole tree
# OpenTofu: `make plan TF=tofu ROOT=...` (identical CLI for everything used here).

TF   ?= terraform
ROOT ?= live/example-app/prod
# Terraform auto-loads <root>/terraform.tfvars. To use another file: VARS=path/to/file.tfvars
VARS ?=
TFLINT_CONFIG := $(CURDIR)/.tflint.hcl

# Paths after -chdir resolve relative to the root, so hand Terraform an absolute path.
VAR_FILE_ARG := $(if $(VARS),-var-file=$(abspath $(VARS)),)

.PHONY: help init fmt fmt-check validate lint plan apply destroy cost output clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

init: ## terraform init in ROOT (lockfile read-only: fails if .terraform.lock.hcl is stale)
	$(TF) -chdir=$(ROOT) init -lockfile=readonly

fmt: ## Format every .tf file in the tree
	$(TF) fmt -recursive

fmt-check: ## Fail if anything is unformatted (CI)
	$(TF) fmt -recursive -check -diff

validate: ## terraform validate ROOT without touching the backend
	$(TF) -chdir=$(ROOT) init -backend=false -input=false >/dev/null
	$(TF) -chdir=$(ROOT) validate

lint: ## tflint (whole tree) + trivy config scan (if installed)
	tflint --init --config=$(TFLINT_CONFIG)
	tflint --recursive --config=$(TFLINT_CONFIG)
	@command -v trivy >/dev/null 2>&1 && trivy config --severity HIGH,CRITICAL --skip-dirs '**/.terraform' . || echo "trivy not installed; skipping (brew install trivy)"

plan: init ## Plan ROOT and save the plan to ROOT/tfplan
	$(TF) -chdir=$(ROOT) plan -input=false $(VAR_FILE_ARG) -out=tfplan

apply: ## Apply the saved plan from `make plan`
	$(TF) -chdir=$(ROOT) apply -input=false tfplan

destroy: init ## Plan a destroy, then apply it (RDS/state bucket prevent_destroy will stop you; see the root README)
	$(TF) -chdir=$(ROOT) plan -destroy -input=false $(VAR_FILE_ARG) -out=tfplan
	$(TF) -chdir=$(ROOT) apply -input=false tfplan

cost: plan ## Infracost breakdown of the saved plan (needs INFRACOST_API_KEY)
	$(TF) -chdir=$(ROOT) show -json tfplan > $(ROOT)/plan.json
	infracost breakdown --path $(ROOT)/plan.json
	@rm -f $(ROOT)/plan.json

output: ## terraform output -json for ROOT
	$(TF) -chdir=$(ROOT) output -json

clean: ## Remove saved plans and provider caches (not state)
	find . -name tfplan -delete -o -name plan.json -delete
	find . -type d -name .terraform -prune -exec rm -rf {} +
