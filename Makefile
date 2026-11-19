.DEFAULT_GOAL := help

include hack/versions.env

.PHONY: help configure up down break reset scenarios lint check cloud-up cloud-down cloud-check

help: ## List the available targets.
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "%-14s %s\n", $$1, $$2}'

configure: ## Prompt for the Sandbox URL and tokens, and write the git-ignored .env.
	bash hack/configure.sh

up: ## Create the kind cluster and deploy the platform and the demo.
	bash hack/up.sh

down: ## Delete the kind cluster.
	bash hack/down.sh

break: ## Inject a Scenario, for example make break SCENARIO=oom.
	bash hack/break.sh "$(SCENARIO)"

reset: ## Force-reset the Sandbox to the known-good tag and remove chaos experiments.
	bash hack/reset.sh

scenarios: ## List the Scenarios that scenarios/ defines.
	@find scenarios -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort

lint: ## Check shell syntax, Python syntax, and the dashboard JSON documents.
	bash -n hack/*.sh
	@for helper in hack/*.py; do python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$$helper"; done
	@for dashboard in platform/observability/dashboards/*.json; do python3 -m json.tool "$$dashboard" >/dev/null; done

check: ## Validate every manifest, every Scenario patch, and the teardown scripts.
	bash hack/validate.sh
	bash hack/cloud-down-order-check.sh
	bash hack/cloud-teardown-check-test.sh
	bash hack/cloud-volume-sweep-test.sh

cloud-up: ## Create the EKS session, deploy the platform, and wait for it to be synced.
	bash hack/cloud-up.sh

cloud-down: ## Destroy the EKS session and prove that nothing billable remains.
	bash hack/cloud-down.sh

cloud-check: ## Check formatting, validation and lint of every Terraform configuration.
	terraform -chdir=infra fmt -check -recursive
	cd infra/bootstrap && terraform init -backend=false -input=false && terraform validate
	cd infra/ci && terraform init -backend=false -input=false && terraform validate
	cd infra && terraform init -backend=false -input=false && terraform validate
	cd infra && tflint --init && tflint --recursive
	bash -n hack/cloud-up.sh hack/cloud-down.sh hack/cloud-teardown-check.sh hack/cloud-volume-sweep.sh \
		hack/cloud-teardown-check-test.sh hack/cloud-volume-sweep-test.sh hack/bootstrap-stack.sh hack/up.sh
	bash hack/cloud-down-order-check.sh
	bash hack/cloud-teardown-check-test.sh
	bash hack/cloud-volume-sweep-test.sh
	bash hack/render-cloud-manifest.sh platform/cloud/karpenter/ec2nodeclass.yaml pagerless pagerless-karpenter-node >/dev/null
	bash hack/render-cloud-manifest.sh platform/cloud/karpenter/nodepool.yaml pagerless pagerless-karpenter-node >/dev/null
	grep -q '__CLUSTER_NAME__' platform/cloud/karpenter/ec2nodeclass.yaml
	grep -q '__NODE_ROLE_NAME__' platform/cloud/karpenter/ec2nodeclass.yaml
