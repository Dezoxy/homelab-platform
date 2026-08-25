# ── version pinning ────────────────────────────────────────────────────────────
# Parse scripts/ci/versions.sh so this file never drifts from CI.
# Each KEY="VALUE" line becomes a Make variable: $(ANSIBLE_VERSION) etc.
_versions := $(shell grep -E '^[A-Za-z_][A-Za-z0-9_]*=' scripts/ci/versions.sh | tr -d '"')
$(foreach _v,$(_versions),$(eval $(_v)))

# ── paths ──────────────────────────────────────────────────────────────────────
VENV      := .venv
LOCAL_BIN := .local/bin
# Local tooling pins require Python >=3.12, while checkov's google-re2
# dependency is not reliably wheel-backed on Python 3.14+. Prefer an explicit
# supported interpreter and still allow `make PYTHON=/path/to/python setup`.
PYTHON    ?= $(shell command -v python3.13 2>/dev/null || command -v python3.12 2>/dev/null || python3 -c 'import sys; print(getattr(sys, "_base_executable", sys.executable))' 2>/dev/null || echo python3)

OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

# ── azure key vault (secret source) ──────────────────────────────────────────────
# Deploys/plans fetch secrets from Azure Key Vault using your ambient `az login`
# session and export them under their original env-var names (restored from each
# secret's `envvar` tag). No client secret stored locally. CI reads the same vault
# via GitHub OIDC (.github/actions/azure-secrets).
AZURE_KEYVAULT_NAME ?= kv-homelab-prod
SECRET_RUN = env \
  AZURE_KEYVAULT_NAME='$(AZURE_KEYVAULT_NAME)' \
  bash scripts/dev/azure_kv_run.sh

# ── targets ────────────────────────────────────────────────────────────────────
.PHONY: all help bootstrap setup setup-hooks install-tools clean \
        ssh-keys \
        lint ci \
        validate-deploy-mode deploy deploy-all deploy-check ensure-image rebuild-media gen-inventory \
        terraform-plan terraform-plan-all destroy \
        hosts roles version \
        register-azure-arc update-all update-pve ping status facts

all: help

## @section Help
## help              show this help (grouped by section)
help:
	@awk 'BEGIN{FS=""} \
	  /^## @section / {printf "\n\033[1m%s\033[0m\n", substr($$0, 13); next} \
	  /^## / {sub(/^## /,"  "); print}' $(MAKEFILE_LIST)

# ── setup ──────────────────────────────────────────────────────────────────────

## @section First-time setup
## bootstrap         first-time setup: venv + git hooks + local CLI tools (run once after cloning)
bootstrap: setup setup-hooks install-tools
	@echo "Bootstrap complete. You're ready to go."

## setup             create .venv with Python CI tools (ansible, ansible-lint, checkov)
setup: $(VENV)/.installed

$(VENV)/.installed: scripts/ci/versions.sh
	@$(PYTHON) -c 'import sys; v=sys.version_info[:2]; sys.exit(0 if (3, 12) <= v < (3, 14) else f"ERROR: {sys.executable} is Python {sys.version.split()[0]}; local tooling pins require Python 3.12 or 3.13. Install python3.13 or run make PYTHON=/path/to/python3.13 setup.")'
	find $(VENV) -name .DS_Store -delete 2>/dev/null || true
	rm -rf $(VENV) || rm -rf $(VENV)
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/python -m pip install --quiet --no-compile \
		"ansible==$(ANSIBLE_VERSION)" \
		"ansible-lint==$(ANSIBLE_LINT_VERSION)" \
		"checkov==$(CHECKOV_VERSION)"
	$(VENV)/bin/ansible-galaxy collection install \
		-r ansible/requirements.yml --force
	$(VENV)/bin/ansible-galaxy collection install \
		"community.docker:$(COMMUNITY_DOCKER_VERSION)" --force-with-deps
	touch $(VENV)/.installed

## setup-hooks       install git pre-commit and pre-push hooks (run once after cloning)
setup-hooks:
	pre-commit install
	@echo "Installed: commit-stage and pre-push-stage hooks"

## install-tools     download tflint and packer binaries to .local/bin/ (required for lint)
install-tools: $(LOCAL_BIN)/tflint $(LOCAL_BIN)/packer

$(LOCAL_BIN)/tflint: scripts/ci/versions.sh
	mkdir -p $(LOCAL_BIN)
	curl -fsSL \
		"https://github.com/terraform-linters/tflint/releases/download/v$(TFLINT_VERSION)/tflint_$(OS)_$(ARCH).zip" \
		-o /tmp/tflint.zip
	unzip -q -o /tmp/tflint.zip tflint -d $(LOCAL_BIN)
	chmod +x $(LOCAL_BIN)/tflint
	touch $(LOCAL_BIN)/tflint
	rm /tmp/tflint.zip
	@echo "tflint $(TFLINT_VERSION) → $(LOCAL_BIN)/tflint"

$(LOCAL_BIN)/packer: scripts/ci/versions.sh
	mkdir -p $(LOCAL_BIN)
	curl -fsSL \
		"https://releases.hashicorp.com/packer/$(PACKER_VERSION)/packer_$(PACKER_VERSION)_$(OS)_$(ARCH).zip" \
		-o /tmp/packer.zip
	unzip -q -o /tmp/packer.zip packer -d $(LOCAL_BIN)
	chmod +x $(LOCAL_BIN)/packer
	touch $(LOCAL_BIN)/packer
	rm /tmp/packer.zip
	@echo "packer $(PACKER_VERSION) → $(LOCAL_BIN)/packer"

## ssh-keys          write ~/.ssh/toomhorvath and ~/.ssh/runner from Key Vault
##                   For a machine that has no local keys of its own -- a fresh
##                   clone, or 01-code-lxc. Requires `az login` first. Not part
##                   of `bootstrap`: on a machine that already has the keys this
##                   would overwrite them from the vault.
ssh-keys:
	@# Only the `ssh` folder. target_secret_folders.sh maps a *deploy* to the
	@# service secrets its plays read; this fetches login credentials instead,
	@# so it names its one folder directly rather than going through that map.
	@#
	@# Captured rather than piped: the script prints `export ...` lines meant
	@# for CI to eval, which are noise here, but `| grep -v` would replace its
	@# exit status with grep's and swallow a failed fetch.
	@set -e; \
	 out="$$(AZURE_KEYVAULT_FOLDER=ssh $(SECRET_RUN) bash scripts/ci/prepare_ssh_keys.sh)"; \
	 printf '%s\n' "$$out" | grep -v '^export ' || true; \
	 for k in toomhorvath runner; do \
	   printf '%s  %s\n' "$$HOME/.ssh/$$k" "$$(ssh-keygen -lf "$$HOME/.ssh/$$k" | awk '{print $$2}')"; \
	 done

## clean             remove .venv and .local/ (forces fresh reinstall on next setup)
clean:
	@for target in $(VENV) $(LOCAL_BIN); do \
		[ -e "$$target" ] || continue; \
		chmod -R u+w "$$target" 2>/dev/null || true; \
		if command -v chflags >/dev/null 2>&1; then \
			chflags -R nouchg,noschg "$$target" 2>/dev/null || true; \
		fi; \
		find "$$target" -name .DS_Store -delete 2>/dev/null || true; \
		if ! rm -rf "$$target"; then \
			echo "rm failed for $$target, retrying with find -delete"; \
			find "$$target" -depth -delete 2>/dev/null || true; \
			rm -rf "$$target" || { \
				echo "ERROR: could not remove $$target. Close any app holding files in it (Finder, editors, running python) and re-run 'make clean'."; \
				exit 1; \
			}; \
		fi; \
	done
	@echo "Removed $(VENV) and $(LOCAL_BIN)"

# ── lint ───────────────────────────────────────────────────────────────────────

## @section Daily workflow
## lint              run all linters and fast tests — mirrors CI validation jobs
lint: setup install-tools
	pre-commit run --all-files
	pre-commit run --hook-stage pre-push --all-files

# ── ci ─────────────────────────────────────────────────────────────────────────

## ci                full local CI: lint  (run before opening a PR)
ci: lint

# ── deploy ─────────────────────────────────────────────────────────────────────

## @section Deploy
## deploy            deploy one host; requires TARGET and explicit MODE
##                   MODE=config   — configuration only; no Terraform, rootfs expansion, or package upgrades
##                   MODE=infra    — infrastructure only, skip Ansible
##                   MODE=full     — Terraform + Ansible
##                   SKIP_UPDATES=true  — with MODE=full, skip apt system updates
##                   SKIP_EXPAND=true   — with MODE=full, skip rootfs expansion
## deploy-all        deploy targets sequentially; requires explicit MODE
##                   one failing target no longer aborts the rest; a summary
##                   of ok/failed/not-attempted prints at the end
##                   FAIL_FAST=true   — stop at the first failing target
TARGET       ?=
MODE         ?=
SKIP_UPDATES ?= false
SKIP_EXPAND  ?= false
FAIL_FAST    ?= false
IMAGE        ?=
ARC_TARGETS  ?= 01-media-vm:01-myapps-vm
ARC_LIMIT    ?= media_vm:myapps_vm

validate-deploy-mode:
	@case "$(MODE)" in \
		config|infra|full) ;; \
		"") \
			echo "MODE is required. Choose one explicitly: MODE=config, MODE=infra, or MODE=full."; \
			exit 2; \
			;; \
		*) \
			echo "Invalid MODE='$(MODE)'. Choose one of: config, infra, full."; \
			exit 2; \
			;; \
	esac

deploy: validate-deploy-mode setup
	@if [ -z "$(TARGET)" ]; then \
		echo "Usage: make deploy TARGET=<host> MODE=config|infra|full"; \
		echo ""; \
		$(MAKE) --no-print-directory hosts; \
		exit 1; \
	fi
	@# Resolve the folder scope in its own assignment under `set -e`. Inlining
	@# the substitution into the env block discards its exit status, so an
	@# unmapped TARGET silently produced an empty AZURE_KEYVAULT_FOLDER -- and
	@# empty means "fetch every secret in the vault" to azure_kv_run.sh, which
	@# is the opposite of what target_secret_folders.sh exists to enforce.
	@set -e; \
	 folders="$$(bash scripts/ci/target_secret_folders.sh $(TARGET))"; \
	 TARGET=$(TARGET) \
	 AZURE_KEYVAULT_FOLDER="$$folders" \
	 ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 ANSIBLE_RUN_SYSTEM_UPDATES=$(if $(filter full,$(MODE)),$(if $(filter true,$(SKIP_UPDATES)),false,true),false) \
	 ANSIBLE_RUN_EXPAND_ROOTFS=$(if $(filter full,$(MODE)),$(if $(filter true,$(SKIP_EXPAND)),false,true),false) \
	 RUN_TERRAFORM=$(if $(filter infra full,$(MODE)),true,false) \
	 RUN_ANSIBLE=$(if $(filter infra,$(MODE)),false,true) \
	 $(SECRET_RUN) bash scripts/ci/run_ansible.sh

deploy-all: validate-deploy-mode setup
	@MODE="$(MODE)" \
	 SKIP_UPDATES="$(SKIP_UPDATES)" \
	 SKIP_EXPAND="$(SKIP_EXPAND)" \
	 FAIL_FAST="$(FAIL_FAST)" \
	 MAKE="$(MAKE)" \
	 bash scripts/ci/deploy_all.sh

## ensure-image       ensure a catalog image exists without changing a workload:
##                    IMAGE=ubuntu-2604-vm-v1 builds template VMID 901 if absent.
ensure-image: setup
	@if [ -z "$(IMAGE)" ]; then \
		echo "Usage: make ensure-image IMAGE=<catalog-image-id>"; \
		exit 1; \
	fi
	@IMAGE_ID=$(IMAGE) \
	 ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 $(SECRET_RUN) bash scripts/ci/ensure_target_image.sh

MEDIA_REBUILD_CONFIRM ?= false

## rebuild-media     controlled media VM replacement after catalog migration:
##                   builds/validates the pinned template before outage, mirrors
##                   root-local application state, captures an offsite restic
##                   snapshot, replaces the VM, and restores services.
rebuild-media: setup
	@ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 ANSIBLE_RUN_SYSTEM_UPDATES=true \
	 ANSIBLE_RUN_EXPAND_ROOTFS=true \
	 MEDIA_REBUILD_CONFIRM=$(MEDIA_REBUILD_CONFIRM) \
	 $(SECRET_RUN) bash scripts/dev/rebuild_media.sh

## terraform-plan      run terraform init + plan against one stack  (TARGET=01-media-vm)
##                     Requires Tailscale connectivity to reach the Proxmox API.
##                     Read-only — never applies. Use to catch drift / preview changes.
terraform-plan: setup
	@if [ -z "$(TARGET)" ]; then \
		echo "Usage: make terraform-plan TARGET=<host>"; \
		echo ""; \
		echo "Available stacks:"; \
		find infra-proxmox/terraform -maxdepth 1 -mindepth 1 -type d ! -name modules ! -name '_*' -exec basename {} \; | sort | sed 's/^/  /'; \
		exit 1; \
	fi
	@$(SECRET_RUN) bash scripts/dev/terraform_plan.sh $(TARGET)

## terraform-plan-all  run terraform init + plan against every stack under infra-proxmox/terraform/
##                     Useful before a refactor merge or after a provider bump.
##                     Stops at the end and reports how many stacks failed; doesn't bail mid-loop.
terraform-plan-all: setup
	@dirs=$$(find infra-proxmox/terraform -maxdepth 1 -mindepth 1 -type d ! -name modules ! -name '_*' -exec basename {} \; | sort | tr '\n' ' '); \
	if [ -z "$$dirs" ]; then \
		echo "No stacks found under infra-proxmox/terraform/" >&2; \
		exit 1; \
	fi; \
	$(SECRET_RUN) bash -c '\
		fail=0; \
		for d in '"$$dirs"'; do \
			bash scripts/dev/terraform_plan.sh "$$d" || fail=$$((fail+1)); \
		done; \
		echo ""; \
		if [ $$fail -gt 0 ]; then \
			echo "$$fail stack(s) failed to plan."; \
			exit 1; \
		fi; \
		echo "All stacks planned successfully."'

## destroy           run terraform destroy against one stack  (TARGET=01-media-vm)
##                   ⚠ DESTRUCTIVE — tears the stack down. Prompts before applying.
##                   Requires Tailscale connectivity to reach the Proxmox API.
destroy: setup
	@if [ -z "$(TARGET)" ]; then \
		echo "Usage: make destroy TARGET=<host>"; \
		echo ""; \
		echo "Available stacks:"; \
		find infra-proxmox/terraform -maxdepth 1 -mindepth 1 -type d ! -name modules ! -name '_*' -exec basename {} \; | sort | sed 's/^/  /'; \
		exit 1; \
	fi
	@if [ ! -d "infra-proxmox/terraform/$(TARGET)" ]; then \
		echo "Terraform stack not found: infra-proxmox/terraform/$(TARGET)"; \
		exit 1; \
	fi
	@echo ""
	@echo "  ⚠  DESTRUCTIVE: this will run 'terraform destroy' against:"
	@echo "       infra-proxmox/terraform/$(TARGET)"
	@echo ""
	@read -p "  Continue? [y/N] " ans && [ "$$ans" = "y" ] || (echo "Aborted." && exit 1)
	@$(SECRET_RUN) bash scripts/dev/terraform_destroy.sh $(TARGET)

## deploy-check      dry-run service configuration (--check --diff); no rootfs expansion or package upgrades
##                   TARGET=01-media-vm required
deploy-check: setup
	@if [ -z "$(TARGET)" ]; then \
		echo "Usage: make deploy-check TARGET=<host>"; \
		echo ""; \
		$(MAKE) --no-print-directory hosts; \
		exit 1; \
	fi
	@play="ansible/playbooks/services/$(TARGET).yml"; \
	if [ ! -f "$$play" ]; then \
		echo "Service playbook not found: $$play"; \
		exit 1; \
	fi
	@# Runs the SAME script as `make deploy`, with --check --diff, rather than
	@# rebuilding a subset of its command. run_ansible.sh injects 29 extra_vars;
	@# the previous hand-rolled version passed 4, so a dry run of 01-edge-lxc
	@# failed on a missing cloudflared token that a real deploy supplies. A
	@# preview that does not share the deploy's code path previews nothing.
	@set -e; \
	 folders="$$(bash scripts/ci/target_secret_folders.sh $(TARGET))"; \
	 TARGET=$(TARGET) \
	 AZURE_KEYVAULT_FOLDER="$$folders" \
	 ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 ANSIBLE_CHECK_MODE=true \
	 ANSIBLE_RUN_SYSTEM_UPDATES=false \
	 ANSIBLE_RUN_EXPAND_ROOTFS=false \
	 RUN_TERRAFORM=false \
	 RUN_ANSIBLE=true \
	 $(SECRET_RUN) bash scripts/ci/run_ansible.sh

# ── operations ────────────────────────────────────────────────────────────────

## @section Operations
## register-azure-arc  register the two VM guests with Azure Arc
##                     Requires AZ_SUBSCRIPTION_ID, AZ_TENANT_ID, AZ_RG,
##                     AZ_LOCATION, ARC_SP_ID, and ARC_SP_SECRET in the env.
register-azure-arc: setup
	@test -n "$$AZ_SUBSCRIPTION_ID" || { echo "Missing AZ_SUBSCRIPTION_ID"; exit 2; }
	@test -n "$$AZ_TENANT_ID" || { echo "Missing AZ_TENANT_ID"; exit 2; }
	@test -n "$$AZ_RG" || { echo "Missing AZ_RG"; exit 2; }
	@test -n "$$AZ_LOCATION" || { echo "Missing AZ_LOCATION"; exit 2; }
	@test -n "$$ARC_SP_ID" || { echo "Missing ARC_SP_ID"; exit 2; }
	@test -n "$$ARC_SP_SECRET" || { echo "Missing ARC_SP_SECRET"; exit 2; }
	@ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 bash scripts/ci/with_attested_ssh_trust.sh "$(ARC_TARGETS)" -- $(VENV)/bin/ansible-playbook \
	     -i ansible/inventory.ini \
	     --limit "$(ARC_LIMIT)" \
	     ansible/playbooks/operations/register-azure-arc.yml

# ── maintenance ────────────────────────────────────────────────────────────────

## @section Maintenance
## update-all         apt update+upgrade every VM and LXC; writes logs/apt-upgrade-YYYY-MM-DD.log
LOG_DIR  ?= logs
LOG_DATE := $(shell date +%Y-%m-%d)

update-all: setup
	@mkdir -p $(LOG_DIR)
	@echo "Running apt update+upgrade on all hosts — log → $(LOG_DIR)/apt-upgrade-$(LOG_DATE).log"
	@ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 APT_LOG_FILE=$(CURDIR)/$(LOG_DIR)/apt-upgrade-$(LOG_DATE).log \
	 bash scripts/ci/with_attested_ssh_trust.sh all -- $(VENV)/bin/ansible-playbook \
	     -i ansible/inventory.ini \
	     ansible/playbooks/maintenance/apt-upgrade-log.yml
	@echo ""
	@echo "Done. Log: $(LOG_DIR)/apt-upgrade-$(LOG_DATE).log"
	@$(MAKE) --no-print-directory update-pve

## update-pve         apt update+upgrade the Proxmox host; writes logs/apt-upgrade-pve-YYYY-MM-DD.log
#
# Separate invocation and separate inventory ON PURPOSE. inventory-proxmox.ini
# is kept apart from inventory.ini so that a `hosts: all` play can never reach
# the hypervisor by accident, and running the playbook twice preserves that
# rather than merging the two.
#
# No with_attested_ssh_trust.sh wrapper here: that exists to attest GUEST host
# keys through pve. The hypervisor itself is the root of trust, so leaving
# ANSIBLE_KNOWN_HOSTS_FILE unset makes ansible_known_hosts_file fall back to
# the committed ansible/ssh_known_hosts, which is the pinned pve key.
update-pve: setup
	@mkdir -p $(LOG_DIR)
	@echo ""
	@echo "Running apt update+upgrade on the Proxmox host - log -> $(LOG_DIR)/apt-upgrade-pve-$(LOG_DATE).log"
	@ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 APT_LOG_FILE=$(CURDIR)/$(LOG_DIR)/apt-upgrade-pve-$(LOG_DATE).log \
	 $(VENV)/bin/ansible-playbook \
	     -i ansible/inventory-proxmox.ini \
	     ansible/playbooks/maintenance/apt-upgrade-log.yml
	@echo ""
	@echo "Done. Log: $(LOG_DIR)/apt-upgrade-pve-$(LOG_DATE).log"

## ping               SSH reachability check across every host
ping: setup
	@ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 bash scripts/ci/with_attested_ssh_trust.sh all -- $(VENV)/bin/ansible all \
	     -i ansible/inventory.ini \
	     -m ansible.builtin.ping \
	     -o

## status             uptime, load, disk, and memory for every host
status: setup
	@ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 bash scripts/ci/with_attested_ssh_trust.sh all -- $(VENV)/bin/ansible all \
	     -i ansible/inventory.ini \
	     -m ansible.builtin.shell \
	     -a 'printf "uptime: "; uptime; printf "disk:   "; df -h / | awk "NR==2 {print \$$3\"/\"\$$2\" (\"\$$5\" used)\"}"; printf "mem:    "; free -h | awk "/^Mem:/ {print \$$3\"/\"\$$2\" used\"}"'

## facts              dump gathered ansible facts for one host  (TARGET=01-media-vm)
facts: setup
	@if [ -z "$(TARGET)" ]; then \
		echo "Usage: make facts TARGET=<host>"; \
		echo ""; \
		$(MAKE) --no-print-directory hosts; \
		exit 1; \
	fi
	@ANSIBLE_CONFIG=ansible/ansible.cfg \
	 ANSIBLE_DEPRECATION_WARNINGS=False \
	 ANSIBLE_HOST_KEY_CHECKING=True \
	 bash scripts/ci/with_attested_ssh_trust.sh "$(TARGET)" -- $(VENV)/bin/ansible $(TARGET) \
	     -i ansible/inventory.ini \
	     -m ansible.builtin.setup

# ── inventory ──────────────────────────────────────────────────────────────────

## @section Inventory
## gen-inventory     regenerate ansible/inventory.ini from Terraform variable defaults
##                   run after adding a host or changing an IP in variables.tf
gen-inventory:
	$(PYTHON) scripts/setup/generate-inventory.py

# ── discovery ──────────────────────────────────────────────────────────────────

## @section Discovery
## hosts             list deployable hosts (from ansible/inventory.ini)
hosts:
	@echo "Deployable hosts:"
	@awk '/ansible_host=/ {print $$1}' ansible/inventory.ini | sort -u | sed 's/^/  /'

## roles             list ansible roles under ansible/roles/
roles:
	@echo "Ansible roles:"
	@ls ansible/roles | sort | sed 's/^/  /'

## version           show pinned tool versions from scripts/ci/versions.sh
version:
	@echo "Pinned versions (scripts/ci/versions.sh):"
	@printf "  %-22s %s\n" \
		"terraform"          "$(TERRAFORM_VERSION)" \
		"packer"             "$(PACKER_VERSION)" \
		"ansible"            "$(ANSIBLE_VERSION)" \
		"ansible-lint"       "$(ANSIBLE_LINT_VERSION)" \
		"tailscale"          "$(TAILSCALE_VERSION)" \
		"actionlint"         "$(ACTIONLINT_VERSION)" \
		"tflint"             "$(TFLINT_VERSION)" \
		"checkov"            "$(CHECKOV_VERSION)" \
		"community.docker"   "$(COMMUNITY_DOCKER_VERSION)"

# ── usage ──────────────────────────────────────────────────────────────────────
#
#  FIRST TIME SETUP
#    make bootstrap      — venv + git hooks + local CLI tools (run once after cloning)
#    make setup          — create .venv only
#    make setup-hooks    — install git hooks only
#    make install-tools  — download tflint and packer to .local/bin/
#    make clean          — wipe .venv and .local/ for a fresh start
#
#  DAILY WORKFLOW
#    make lint           — run all linters and fast tests
#    make ci             — full pre-PR check: lint (mirrors GitHub Actions)
#
#  DEPLOYING TO A HOST
#    Secrets come from Azure Key Vault. Local Make targets read them via your
#    ambient `az login` session (run `az login` once); no client secret on disk.
#
#    make deploy TARGET=01-media-vm MODE=config         — configuration only
#    make deploy TARGET=01-media-vm MODE=full           — Terraform + Ansible
#    make deploy TARGET=01-media-vm MODE=infra          — Terraform only
#    make deploy-all MODE=config                        — configure all targets sequentially
#    make deploy-all MODE=full                          — full deploy of all targets
#    make deploy TARGET=01-media-vm MODE=full SKIP_UPDATES=true — full deploy without apt upgrades
#    make deploy TARGET=01-media-vm MODE=full SKIP_EXPAND=true  — full deploy without rootfs expansion
#    make deploy TARGET=01-media-vm                     — rejected: MODE must be explicit
#    make deploy-check TARGET=01-media-vm               — dry-run: show diff, change nothing
#
#  BASE IMAGE / STATEFUL VM REBUILD
#    make ensure-image IMAGE=ubuntu-2604-vm-v1          — ensure VM template 901 exists
#    make rebuild-media                                  — guarded media VM replacement
#
#  TESTING TERRAFORM CHANGES (read-only)
#    make terraform-plan TARGET=01-media-vm   — plan one stack
#    make terraform-plan-all                  — plan every stack
#    Both require Tailscale connectivity for Proxmox API reachability.
#
#  TEARING DOWN A STACK (destructive)
#    make destroy TARGET=01-media-vm          — terraform destroy on one stack (prompts)
#
#  OPERATIONS
#    make register-azure-arc                  — onboard 01-media-vm and 01-myapps-vm to Azure Arc
#
#  SECRETS (Azure Key Vault)
#    az login                                  — authenticate the local CLI session
#    make deploy/terraform-plan ...            — secrets fetched from the vault automatically
#    AZURE_KEYVAULT_NAME=<name> ...            — override the default vault if needed
#
#  MAINTENANCE
#    make update-all     — apt update+upgrade all VMs/LXCs, write logs/apt-upgrade-YYYY-MM-DD.log
#    make ping           — SSH reachability check across every host
#    make status         — uptime, load, disk, memory per host
#    make facts TARGET=X — dump ansible facts for one host
#
#  INVENTORY
#    make gen-inventory  — rebuild inventory.ini from Terraform variable defaults
#
#  DISCOVERY
#    make hosts          — list deployable hosts
#    make roles          — list ansible roles
#    make version        — show pinned tool versions
#
#  NOTES
#    · Tailscale must be connected for deploy to reach any host
#    · all targets read version pins from scripts/ci/versions.sh
