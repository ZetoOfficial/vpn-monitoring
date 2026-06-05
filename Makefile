ANSIBLE_DIR := ansible
INVENTORY := $(ANSIBLE_DIR)/inventory.yml

.PHONY: setup ping deploy-monitoring deploy-all status check

setup:
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml -p .ansible/collections

ping:
	cd $(ANSIBLE_DIR) && ansible all -i inventory.yml -m ping

deploy-monitoring:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/monitoring.yml

deploy-all:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/site.yml

status:
	cd $(ANSIBLE_DIR) && ansible all -i inventory.yml -m shell -a 'docker ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}"'

check:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/site.yml --syntax-check
