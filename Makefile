ANSIBLE_DIR := ansible
INVENTORY := $(ANSIBLE_DIR)/inventory.yml
DASHBOARD_DIR := monitoring/grafana/dashboards

.PHONY: setup wg-admin-init ping deploy-monitoring deploy-exporters deploy-all status check download-dashboards

setup:
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml -p .ansible/collections

wg-admin-init:
	@INVENTORY=$(INVENTORY) scripts/init-admin-wg.sh

ping:
	cd $(ANSIBLE_DIR) && ansible all -i inventory.yml -m ping

deploy-monitoring:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/monitoring.yml

deploy-exporters:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/exporters.yml

deploy-all:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/site.yml

status:
	cd $(ANSIBLE_DIR) && ansible all -i inventory.yml -m shell -a 'docker ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}"'

check:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/site.yml --syntax-check

download-dashboards:
	@mkdir -p $(DASHBOARD_DIR)
	@curl -fsSL https://grafana.com/api/dashboards/1860/revisions/37/download -o $(DASHBOARD_DIR)/node-exporter-full.json
	@curl -fsSL https://grafana.com/api/dashboards/14282/revisions/1/download -o $(DASHBOARD_DIR)/cadvisor.json
	@curl -fsSL https://grafana.com/api/dashboards/12177/revisions/1/download -o $(DASHBOARD_DIR)/wireguard.json
	@for f in $(DASHBOARD_DIR)/*.json; do \
		sed -i.bak 's/"$${DS_PROMETHEUS}"/"prometheus"/g' "$$f" && rm "$$f.bak"; \
	done
	@echo "Downloaded and patched dashboards into $(DASHBOARD_DIR)"
