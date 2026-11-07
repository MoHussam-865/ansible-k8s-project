# =============================================================================
# Makefile — common automation targets for the k8s-ansible project
# =============================================================================
# Usage:
#   make syntax     — Check playbook syntax
#   make hosts      — Show inventory hosts
#   make ls-tags    — List all available tags
#   make dry-run    — Dry-run the full site.yml playbook
#   make deploy     — Run the full site.yml playbook
#   make bootstrap  — Run only OS bootstrap
#   make haproxy    — Run only HAProxy playbook
#   make kubernetes — Run only Kubernetes cluster playbook
#   make verify     — Run only verification playbook
#   make monitoring — Run only monitoring playbook
#   make lint       — Run ansible-lint on all playbooks and roles
#   make install    — Install required collections and roles
#   make clean      — Remove cache, log, and retry files
# =============================================================================

ANSIBLE_PLAYBOOK ?= ansible-playbook
ANSIBLE_INVENTORY ?= ansible-inventory
ANSIBLE_LINT ?= ansible-lint
ANSIBLE_GALAXY ?= ansible-galaxy
PLAYBOOKS_DIR := playbooks

.PHONY: syntax hosts ls-tags dry-run deploy bootstrap haproxy kubernetes verify monitoring lint install clean

# ---------------------------------------------------------------------------
# hosts — show all inventory hosts and groups
# ---------------------------------------------------------------------------
hosts:
	$(ANSIBLE_INVENTORY) --list

# ---------------------------------------------------------------------------
# ls-tags — list all available tags across all playbooks
# ---------------------------------------------------------------------------
ls-tags:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/site.yml --list-tags 2>/dev/null

# ---------------------------------------------------------------------------
# syntax — check syntax of all playbooks
# ---------------------------------------------------------------------------
syntax:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/site.yml --syntax-check
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/bootstrap.yml --syntax-check
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/haproxy.yml --syntax-check
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/kubernetes-cluster.yml --syntax-check
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/verify.yml --syntax-check
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/monitoring.yml --syntax-check

# ---------------------------------------------------------------------------
# dry-run — check-mode (no changes applied)
# ---------------------------------------------------------------------------
dry-run:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/site.yml --check --diff

# ---------------------------------------------------------------------------
# deploy — full provisioning pipeline
# ---------------------------------------------------------------------------
deploy:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/site.yml

# ---------------------------------------------------------------------------
# Individual playbook targets
# ---------------------------------------------------------------------------
bootstrap:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/bootstrap.yml

haproxy:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/haproxy.yml

kubernetes:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/kubernetes-cluster.yml

verify:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/verify.yml

monitoring:
	$(ANSIBLE_PLAYBOOK) $(PLAYBOOKS_DIR)/monitoring.yml

# ---------------------------------------------------------------------------
# lint — run ansible-lint on all playbooks and roles
# ---------------------------------------------------------------------------
lint:
	$(ANSIBLE_LINT) $(PLAYBOOKS_DIR)/*.yml
	$(ANSIBLE_LINT) $(PLAYBOOKS_DIR)/roles/*/

# ---------------------------------------------------------------------------
# install — install required collections
# ---------------------------------------------------------------------------
install:
	$(ANSIBLE_GALAXY) collection install -r collections/requirements.yml

# ---------------------------------------------------------------------------
# clean — remove generated files
# ---------------------------------------------------------------------------
clean:
	rm -rf cache/ retry-files/ ansible.log .retries/
	find . -name '*.retry' -delete
	@echo "Cleaned cache, logs, and retry files."