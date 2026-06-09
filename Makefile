ANSIBLE_DIR := ansible
INVENTORY := $(ANSIBLE_DIR)/inventory.yml

.PHONY: setup ping deploy backup restore status check

setup:
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml -p .ansible/collections

ping:
	cd $(ANSIBLE_DIR) && ansible all -i inventory.yml -m ping

deploy:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/site.yml

backup:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/backup.yml

# Usage: make restore BACKUP=backups/<host>/awg_backup_xxx.tar.gz.age
restore:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/restore.yml -e backup_file=../$(BACKUP)

status:
	cd $(ANSIBLE_DIR) && ansible all -i inventory.yml -m shell -a 'docker ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}"'

check:
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.yml playbooks/site.yml --syntax-check
