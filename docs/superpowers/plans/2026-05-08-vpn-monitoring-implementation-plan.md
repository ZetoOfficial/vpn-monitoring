# VPN Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible Ansible + Docker Compose deployment for VPN monitoring, with `vdsina.com` as the monitoring host and `vdsina.2g.com` as the primary VPN exporter host.

**Architecture:** The repository contains Ansible playbooks, roles, templates, and a Makefile. Ansible connects over SSH, installs Docker, renders Docker Compose projects, configures firewall rules, and starts Prometheus/Grafana/blackbox on `vdsina.com` plus exporters on `vdsina.2g.com`. The first rollout is side-by-side with the current server state: old WireGuard on `vdsina.com` is not removed automatically.

**Tech Stack:** Ansible, Docker Compose, Prometheus, Grafana, blackbox_exporter, node_exporter, wireguard_exporter, cAdvisor, UFW, GNU Make.

---

## Current Server State Impact

The current state matters and changes the rollout order:

- `vdsina.com` still has active WireGuard clients, an old `/root/wgdashboard` checkout, and a live `wg0` on UDP `54651`.
- The MVP must not remove or overwrite that existing VPN setup.
- The firewall must keep the legacy WireGuard UDP port open until those clients are intentionally migrated away.
- Admin access for Grafana should use a new WireGuard interface, `wg-admin`, on a new UDP port, `51821`.
- Monitoring files should live under `/opt/monitoring`, not under `/root/wgdashboard`.
- `vdsina.2g.com` already runs `wg-easy`; exporter deployment must not touch or restart the existing `wg-easy` compose project.
- Firewall changes must be additive and targeted: allow monitoring scrape ports only from `vdsina.com`.

## File Structure

- Create `Makefile`: local operator commands wrapping Ansible.
- Create `ansible/ansible.cfg`: default inventory, roles path, SSH behavior.
- Create `ansible/inventory.example.yml`: sample host inventory and required variables.
- Create `ansible/playbooks/site.yml`: deploy monitoring and exporters together.
- Create `ansible/playbooks/monitoring.yml`: deploy only the monitoring host.
- Create `ansible/playbooks/exporters.yml`: deploy only exporter hosts.
- Create `ansible/roles/common/tasks/main.yml`: package cache, base packages, directories.
- Create `ansible/roles/docker/tasks/main.yml`: install Docker and Compose plugin.
- Create `ansible/roles/admin_wireguard/tasks/main.yml`: configure the separate admin VPN on `vdsina.com`.
- Create `ansible/roles/admin_wireguard/templates/wg-admin.conf.j2`: admin WireGuard config.
- Create `ansible/roles/firewall/tasks/monitoring_host.yml`: monitoring-host firewall rules.
- Create `ansible/roles/firewall/tasks/exporter_host.yml`: exporter-host firewall rules.
- Create `ansible/roles/monitoring_stack/tasks/main.yml`: render and start monitoring compose project.
- Create `ansible/roles/monitoring_stack/templates/docker-compose.yml.j2`: Prometheus/Grafana/blackbox compose.
- Create `ansible/roles/monitoring_stack/templates/prometheus.yml.j2`: scrape config.
- Create `ansible/roles/monitoring_stack/templates/blackbox.yml.j2`: probe modules.
- Create `ansible/roles/vpn_exporters/tasks/main.yml`: render and start exporter compose project.
- Create `ansible/roles/vpn_exporters/templates/docker-compose.yml.j2`: node_exporter/wireguard_exporter/cadvisor compose.
- Create `docs/runbook.md`: setup, deploy, status, rollback, and tunnel/admin VPN notes.

## Task 1: Repository Skeleton

**Files:**
- Create: `Makefile`
- Create: `ansible/ansible.cfg`
- Create: `ansible/inventory.example.yml`
- Create: `ansible/playbooks/site.yml`
- Create: `ansible/playbooks/monitoring.yml`
- Create: `ansible/playbooks/exporters.yml`

- [ ] **Step 1: Create the directory skeleton**

Create these directories:

```bash
mkdir -p ansible/playbooks ansible/roles/{common,docker,admin_wireguard,firewall,monitoring_stack,vpn_exporters}/{tasks,templates} docs
```

Expected: command exits with code `0`.

- [ ] **Step 2: Create `ansible/ansible.cfg`**

```ini
[defaults]
inventory = inventory.yml
roles_path = roles
host_key_checking = True
retry_files_enabled = False
stdout_callback = yaml

[ssh_connection]
pipelining = True
```

- [ ] **Step 3: Create `ansible/inventory.example.yml`**

```yaml
all:
  vars:
    ansible_user: root
    monitoring_public_ip: "203.0.113.10"
    vpn_public_ip: "203.0.113.20"
    admin_wg_interface: wg-admin
    admin_wg_port: 51821
    admin_wg_address: "10.88.0.1/24"
    admin_wg_bind_ip: "10.88.0.1"
    admin_wg_client_allowed_ip: "10.88.0.2/32"
    admin_wg_private_key: "replace-with-server-private-key"
    admin_wg_client_public_key: "replace-with-client-public-key"
    legacy_wg_udp_ports:
      - "54651"
    grafana_admin_user: admin
    grafana_admin_password: "replace-with-local-secret"
    prometheus_retention: 15d
    prometheus_scrape_interval: 30s
    monitoring_base_dir: /opt/monitoring
    exporters_base_dir: /opt/vpn-exporters

  children:
    monitoring:
      hosts:
        vdsina_monitoring:
          ansible_host: "203.0.113.10"

    vpn_exporters:
      hosts:
        vdsina_2g:
          ansible_host: "203.0.113.20"
          wireguard_interface: wg0
```

- [ ] **Step 4: Create `ansible/playbooks/monitoring.yml`**

```yaml
---
- name: Deploy monitoring host
  hosts: monitoring
  become: true
  roles:
    - common
    - docker
    - admin_wireguard
    - monitoring_stack
```

- [ ] **Step 5: Create `ansible/playbooks/exporters.yml`**

```yaml
---
- name: Deploy VPN exporters
  hosts: vpn_exporters
  become: true
  roles:
    - common
    - docker
    - vpn_exporters
```

- [ ] **Step 6: Create `ansible/playbooks/site.yml`**

```yaml
---
- import_playbook: monitoring.yml
- import_playbook: exporters.yml
```

- [ ] **Step 7: Create `Makefile`**

```make
ANSIBLE_DIR := ansible
INVENTORY := $(ANSIBLE_DIR)/inventory.yml

.PHONY: ping deploy-monitoring deploy-exporters deploy-all status check

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
```

- [ ] **Step 8: Verify skeleton**

Run:

```bash
find ansible -maxdepth 3 -type f | sort
```

Expected output includes:

```text
ansible/ansible.cfg
ansible/inventory.example.yml
ansible/playbooks/exporters.yml
ansible/playbooks/monitoring.yml
ansible/playbooks/site.yml
```

- [ ] **Step 9: Commit**

```bash
git add Makefile ansible
git commit -m "Add Ansible project skeleton"
```

## Task 2: Common And Docker Roles

**Files:**
- Create: `ansible/roles/common/tasks/main.yml`
- Create: `ansible/roles/docker/tasks/main.yml`

- [ ] **Step 1: Create `ansible/roles/common/tasks/main.yml`**

```yaml
---
- name: Update apt cache
  ansible.builtin.apt:
    update_cache: true
    cache_valid_time: 3600

- name: Install base packages
  ansible.builtin.apt:
    name:
      - ca-certificates
      - curl
      - gnupg
      - lsb-release
      - ufw
      - wireguard-tools
    state: present

- name: Create monitoring base directory when configured
  ansible.builtin.file:
    path: "{{ monitoring_base_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  when: monitoring_base_dir is defined

- name: Create exporters base directory when configured
  ansible.builtin.file:
    path: "{{ exporters_base_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  when: exporters_base_dir is defined
```

- [ ] **Step 2: Create `ansible/roles/docker/tasks/main.yml`**

```yaml
---
- name: Install Docker packages from distribution repository
  ansible.builtin.apt:
    name:
      - docker.io
      - docker-compose-plugin
    state: present

- name: Ensure Docker service is enabled and running
  ansible.builtin.service:
    name: docker
    state: started
    enabled: true
```

- [ ] **Step 3: Run syntax check**

Run:

```bash
make check
```

Expected: Ansible reports syntax check success for `playbooks/site.yml`.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/common ansible/roles/docker
git commit -m "Add common and Docker roles"
```

## Task 3: Admin WireGuard Role

**Files:**
- Create: `ansible/roles/admin_wireguard/tasks/main.yml`
- Create: `ansible/roles/admin_wireguard/templates/wg-admin.conf.j2`

- [ ] **Step 1: Create `ansible/roles/admin_wireguard/templates/wg-admin.conf.j2`**

```ini
[Interface]
Address = {{ admin_wg_address }}
ListenPort = {{ admin_wg_port }}
PrivateKey = {{ admin_wg_private_key }}

[Peer]
PublicKey = {{ admin_wg_client_public_key }}
AllowedIPs = {{ admin_wg_client_allowed_ip }}
```

- [ ] **Step 2: Create `ansible/roles/admin_wireguard/tasks/main.yml`**

```yaml
---
- name: Assert admin WireGuard variables are configured
  ansible.builtin.assert:
    that:
      - admin_wg_interface | length > 0
      - admin_wg_port | int > 0
      - admin_wg_address | length > 0
      - admin_wg_bind_ip | length > 0
      - admin_wg_private_key != "replace-with-server-private-key"
      - admin_wg_client_public_key != "replace-with-client-public-key"
      - admin_wg_client_allowed_ip | length > 0
    fail_msg: "Admin WireGuard variables must be set in ansible/inventory.yml before deployment."

- name: Install admin WireGuard config
  ansible.builtin.template:
    src: wg-admin.conf.j2
    dest: "/etc/wireguard/{{ admin_wg_interface }}.conf"
    owner: root
    group: root
    mode: "0600"
  notify: Restart admin WireGuard

- name: Enable and start admin WireGuard
  ansible.builtin.service:
    name: "wg-quick@{{ admin_wg_interface }}"
    enabled: true
    state: started

- name: Allow admin WireGuard UDP port
  community.general.ufw:
    rule: allow
    port: "{{ admin_wg_port }}"
    proto: udp

- name: Ensure UFW is enabled
  community.general.ufw:
    state: enabled

handlers:
  - name: Restart admin WireGuard
    ansible.builtin.service:
      name: "wg-quick@{{ admin_wg_interface }}"
      state: restarted
```

- [ ] **Step 3: Add collection note to runbook draft**

Create `docs/runbook.md` with:

````markdown
# VPN Monitoring Runbook

## Local prerequisites

Install Ansible and the UFW collection:

```bash
python3 -m pip install --user ansible
ansible-galaxy collection install community.general
```

Copy the inventory example:

```bash
cp ansible/inventory.example.yml ansible/inventory.yml
```

Edit `ansible/inventory.yml` and replace all sample IPs, Grafana credentials, and WireGuard keys before deploying.
````

- [ ] **Step 4: Run syntax check**

Run:

```bash
make check
```

Expected: syntax check succeeds.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/admin_wireguard docs/runbook.md
git commit -m "Add admin WireGuard role"
```

## Task 4: Monitoring Stack Role

**Files:**
- Create: `ansible/roles/monitoring_stack/tasks/main.yml`
- Create: `ansible/roles/monitoring_stack/templates/docker-compose.yml.j2`
- Create: `ansible/roles/monitoring_stack/templates/prometheus.yml.j2`
- Create: `ansible/roles/monitoring_stack/templates/blackbox.yml.j2`

- [ ] **Step 1: Create monitoring compose template**

Create `ansible/roles/monitoring_stack/templates/docker-compose.yml.j2`:

```yaml
services:
  prometheus:
    image: prom/prometheus:v2.55.1
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time={{ prometheus_retention }}
      - --web.enable-lifecycle
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"

  grafana:
    image: grafana/grafana:11.3.1
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: "{{ grafana_admin_user }}"
      GF_SECURITY_ADMIN_PASSWORD: "{{ grafana_admin_password }}"
      GF_SERVER_HTTP_ADDR: "0.0.0.0"
    volumes:
      - grafana-data:/var/lib/grafana
    ports:
      - "{{ admin_wg_bind_ip }}:3000:3000"

  blackbox_exporter:
    image: prom/blackbox-exporter:v0.25.0
    container_name: blackbox_exporter
    restart: unless-stopped
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro
    ports:
      - "127.0.0.1:9115:9115"

volumes:
  prometheus-data:
  grafana-data:
```

- [ ] **Step 2: Create Prometheus config template**

Create `ansible/roles/monitoring_stack/templates/prometheus.yml.j2`:

```yaml
global:
  scrape_interval: {{ prometheus_scrape_interval }}
  evaluation_interval: {{ prometheus_scrape_interval }}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - prometheus:9090

  - job_name: blackbox
    metrics_path: /probe
    params:
      module:
        - http_2xx
    static_configs:
      - targets:
          - https://cloudflare.com
          - https://google.com
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox_exporter:9115

{% for host in groups['vpn_exporters'] %}
  - job_name: node_{{ host }}
    static_configs:
      - targets:
          - "{{ hostvars[host].ansible_host }}:9100"

  - job_name: cadvisor_{{ host }}
    static_configs:
      - targets:
          - "{{ hostvars[host].ansible_host }}:8080"

  - job_name: wireguard_{{ host }}
    static_configs:
      - targets:
          - "{{ hostvars[host].ansible_host }}:9586"
{% endfor %}
```

- [ ] **Step 3: Create blackbox config template**

Create `ansible/roles/monitoring_stack/templates/blackbox.yml.j2`:

```yaml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions:
        - HTTP/1.1
        - HTTP/2.0
      follow_redirects: true
      preferred_ip_protocol: ip4
```

- [ ] **Step 4: Create monitoring stack tasks**

Create `ansible/roles/monitoring_stack/tasks/main.yml`:

```yaml
---
- name: Assert Grafana password is configured
  ansible.builtin.assert:
    that:
      - grafana_admin_password != "replace-with-local-secret"
      - grafana_admin_password | length >= 12
    fail_msg: "Set a real grafana_admin_password with at least 12 characters in ansible/inventory.yml."

- name: Create monitoring config directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop:
    - "{{ monitoring_base_dir }}"
    - "{{ monitoring_base_dir }}/prometheus"
    - "{{ monitoring_base_dir }}/blackbox"

- name: Render monitoring docker compose
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ monitoring_base_dir }}/docker-compose.yml"
    owner: root
    group: root
    mode: "0600"

- name: Render Prometheus config
  ansible.builtin.template:
    src: prometheus.yml.j2
    dest: "{{ monitoring_base_dir }}/prometheus/prometheus.yml"
    owner: root
    group: root
    mode: "0644"

- name: Render blackbox config
  ansible.builtin.template:
    src: blackbox.yml.j2
    dest: "{{ monitoring_base_dir }}/blackbox/blackbox.yml"
    owner: root
    group: root
    mode: "0644"

- name: Start monitoring stack
  ansible.builtin.command:
    cmd: docker compose up -d
    chdir: "{{ monitoring_base_dir }}"
  changed_when: "'Started' in monitoring_compose.stdout or 'Created' in monitoring_compose.stdout or 'Recreated' in monitoring_compose.stdout"
  register: monitoring_compose
```

- [ ] **Step 5: Run syntax check**

Run:

```bash
make check
```

Expected: syntax check succeeds.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/monitoring_stack
git commit -m "Add monitoring stack role"
```

## Task 5: VPN Exporters Role

**Files:**
- Create: `ansible/roles/vpn_exporters/tasks/main.yml`
- Create: `ansible/roles/vpn_exporters/templates/docker-compose.yml.j2`

- [ ] **Step 1: Create exporter compose template**

Create `ansible/roles/vpn_exporters/templates/docker-compose.yml.j2`:

```yaml
services:
  node_exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node_exporter
    restart: unless-stopped
    command:
      - --path.rootfs=/host
    pid: host
    volumes:
      - /:/host:ro,rslave
    ports:
      - "9100:9100"

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/kmsg:/dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    ports:
      - "8080:8080"

  wireguard_exporter:
    image: mindflavor/prometheus-wireguard-exporter:3.6.6
    container_name: wireguard_exporter
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    network_mode: host
    command:
      - -i
      - "{{ wireguard_interface }}"
```

- [ ] **Step 2: Create exporter tasks**

Create `ansible/roles/vpn_exporters/tasks/main.yml`:

```yaml
---
- name: Assert WireGuard interface is configured
  ansible.builtin.assert:
    that:
      - wireguard_interface | length > 0
    fail_msg: "Set wireguard_interface for each vpn_exporters host."

- name: Create exporters directory
  ansible.builtin.file:
    path: "{{ exporters_base_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Render exporters docker compose
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ exporters_base_dir }}/docker-compose.yml"
    owner: root
    group: root
    mode: "0644"

- name: Start VPN exporters
  ansible.builtin.command:
    cmd: docker compose up -d
    chdir: "{{ exporters_base_dir }}"
  changed_when: "'Started' in exporters_compose.stdout or 'Created' in exporters_compose.stdout or 'Recreated' in exporters_compose.stdout"
  register: exporters_compose
```

- [ ] **Step 3: Run syntax check**

Run:

```bash
make check
```

Expected: syntax check succeeds.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/vpn_exporters
git commit -m "Add VPN exporters role"
```

## Task 6: Firewall Role

**Files:**
- Modify: `ansible/playbooks/monitoring.yml`
- Modify: `ansible/playbooks/exporters.yml`
- Create: `ansible/roles/firewall/tasks/main.yml`
- Create: `ansible/roles/firewall/tasks/monitoring_host.yml`
- Create: `ansible/roles/firewall/tasks/exporter_host.yml`

- [ ] **Step 1: Create firewall dispatcher**

Create `ansible/roles/firewall/tasks/main.yml`:

```yaml
---
- name: Configure monitoring host firewall
  ansible.builtin.include_tasks: monitoring_host.yml
  when: "'monitoring' in group_names"

- name: Configure exporter host firewall
  ansible.builtin.include_tasks: exporter_host.yml
  when: "'vpn_exporters' in group_names"
```

- [ ] **Step 2: Create monitoring host firewall tasks**

Create `ansible/roles/firewall/tasks/monitoring_host.yml`:

```yaml
---
- name: Allow SSH
  community.general.ufw:
    rule: allow
    port: "22"
    proto: tcp

- name: Allow admin WireGuard
  community.general.ufw:
    rule: allow
    port: "{{ admin_wg_port }}"
    proto: udp

- name: Keep legacy WireGuard UDP ports open during migration
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
    proto: udp
  loop: "{{ legacy_wg_udp_ports | default([]) }}"

- name: Enable UFW on monitoring host
  community.general.ufw:
    state: enabled
```

- [ ] **Step 3: Create exporter host firewall tasks**

Create `ansible/roles/firewall/tasks/exporter_host.yml`:

```yaml
---
- name: Allow SSH
  community.general.ufw:
    rule: allow
    port: "22"
    proto: tcp

- name: Allow node_exporter from monitoring host
  community.general.ufw:
    rule: allow
    from_ip: "{{ monitoring_public_ip }}"
    port: "9100"
    proto: tcp

- name: Allow cAdvisor from monitoring host
  community.general.ufw:
    rule: allow
    from_ip: "{{ monitoring_public_ip }}"
    port: "8080"
    proto: tcp

- name: Allow wireguard_exporter from monitoring host
  community.general.ufw:
    rule: allow
    from_ip: "{{ monitoring_public_ip }}"
    port: "9586"
    proto: tcp

- name: Enable UFW on exporter host
  community.general.ufw:
    state: enabled
```

- [ ] **Step 4: Add firewall role to monitoring playbook**

Update `ansible/playbooks/monitoring.yml`:

```yaml
---
- name: Deploy monitoring host
  hosts: monitoring
  become: true
  roles:
    - common
    - docker
    - admin_wireguard
    - monitoring_stack
    - firewall
```

- [ ] **Step 5: Add firewall role to exporters playbook**

Update `ansible/playbooks/exporters.yml`:

```yaml
---
- name: Deploy VPN exporters
  hosts: vpn_exporters
  become: true
  roles:
    - common
    - docker
    - vpn_exporters
    - firewall
```

- [ ] **Step 6: Run syntax check**

Run:

```bash
make check
```

Expected: syntax check succeeds.

- [ ] **Step 7: Commit**

```bash
git add ansible/playbooks ansible/roles/firewall
git commit -m "Add firewall role"
```

## Task 7: Runbook And Preflight

**Files:**
- Modify: `docs/runbook.md`

- [ ] **Step 1: Add current-state preflight section**

Append to `docs/runbook.md`:

````markdown
## Preflight before first deployment

Run these manually before the first deployment.

On `vdsina.com`:

```bash
wg show
ss -tulpn
docker ps
ls -la /root/wgdashboard || true
```

Confirm:

- Existing `wg0` stays on its current port.
- UDP `51821` is free for `wg-admin`.
- TCP `3000` is not already used by another host-level process.
- There is enough free memory for Prometheus and Grafana.

On `vdsina.2g.com`:

```bash
wg show
docker ps
ss -tulpn
```

Confirm:

- Existing `wg-easy` is running.
- Exporter ports `9100`, `8080`, and `9586` are free or intentionally reusable.
- `wireguard_interface` in inventory matches the real WireGuard interface.

## First deployment

From the local repository:

```bash
cp ansible/inventory.example.yml ansible/inventory.yml
vim ansible/inventory.yml
make ping
make check
make deploy-monitoring
make deploy-exporters
make status
```

## Access Grafana

Primary access is through the admin WireGuard tunnel to `vdsina.com`.

Fallback SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 root@vdsina.com
```

Then open:

```text
http://127.0.0.1:3000
```

## Rollback

Stop monitoring stack on `vdsina.com`:

```bash
cd /opt/monitoring
docker compose down
```

Stop exporters on `vdsina.2g.com`:

```bash
cd /opt/vpn-exporters
docker compose down
```

Disable admin WireGuard on `vdsina.com`:

```bash
systemctl disable --now wg-quick@wg-admin
```
````

- [ ] **Step 2: Commit**

```bash
git add docs/runbook.md
git commit -m "Document deployment runbook"
```

## Task 8: Local Validation

**Files:**
- No file changes expected.

- [ ] **Step 1: Copy inventory example locally**

Run:

```bash
cp ansible/inventory.example.yml ansible/inventory.yml
```

Expected: `ansible/inventory.yml` exists and is ignored by git.

- [ ] **Step 2: Verify ignored inventory**

Run:

```bash
git status --short
```

Expected: `ansible/inventory.yml` is not listed.

- [ ] **Step 3: Run Ansible syntax check**

Run:

```bash
make check
```

Expected: syntax check succeeds after replacing sample secrets in the local inventory, or fails only on explicit assert checks during execution, not YAML syntax.

- [ ] **Step 4: Verify working tree**

Run:

```bash
git status --short
```

Expected: no tracked changes after commits, ignored `ansible/inventory.yml` may exist silently.

## Task 9: First Real Deployment Checkpoint

**Files:**
- No repository changes expected unless deployment reveals required fixes.

- [ ] **Step 1: Fill local inventory**

Edit `ansible/inventory.yml` with real values:

```yaml
monitoring_public_ip: "<real vdsina.com public IPv4>"
vpn_public_ip: "<real vdsina.2g.com public IPv4>"
admin_wg_private_key: "<new wg-admin server private key>"
admin_wg_client_public_key: "<admin client public key>"
grafana_admin_password: "<strong local password>"
```

- [ ] **Step 2: Verify SSH connectivity**

Run:

```bash
make ping
```

Expected: both hosts return `pong`.

- [ ] **Step 3: Deploy monitoring host**

Run:

```bash
make deploy-monitoring
```

Expected:

- Docker is installed on `vdsina.com`.
- `/opt/monitoring/docker-compose.yml` exists.
- `prometheus`, `grafana`, and `blackbox_exporter` containers are running.
- Existing `wg0` remains running.
- New `wg-admin` is running on UDP `51821`.

- [ ] **Step 4: Deploy exporter host**

Run:

```bash
make deploy-exporters
```

Expected:

- Docker remains running on `vdsina.2g.com`.
- Existing `wg-easy` remains running.
- `node_exporter`, `cadvisor`, and `wireguard_exporter` containers are running.
- Exporter ports are reachable from `vdsina.com`.

- [ ] **Step 5: Check Prometheus targets**

Open Grafana/Prometheus through admin VPN or SSH tunnel and verify Prometheus targets:

```text
prometheus
blackbox
node_vdsina_2g
cadvisor_vdsina_2g
wireguard_vdsina_2g
```

Expected: all targets are `UP`.

- [ ] **Step 6: Commit fixes if deployment reveals issues**

If any role needs adjustment:

```bash
git add <changed-files>
git commit -m "Fix monitoring deployment issue"
```
