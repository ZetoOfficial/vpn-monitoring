# VPN Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible Ansible + Docker Compose deployment for VPN monitoring, with `vdsina.com` as the monitoring host and `vdsina.2gb.com` as the primary VPN exporter host. Grafana ships pre-provisioned with three community dashboards and Prometheus evaluates a baseline of alert rules locally.

**Architecture:** Ansible over SSH installs Docker from the official Docker repo, configures UFW first (so the SSH connection survives), brings up `wg-admin` on the monitoring host, then renders Docker Compose projects for the monitoring stack and the exporters. Static monitoring artifacts (alerts, dashboards, datasource provisioning, blackbox config) live under `monitoring/` in the repo and are copied to the target hosts as-is; per-host config (Prometheus scrape targets, Compose with templated paths) lives in role templates.

**Tech Stack:** Ansible (`community.general` collection), Docker CE + Compose plugin from the official Docker repo, Prometheus, Grafana, Blackbox Exporter, Node Exporter, Wireguard Exporter, cAdvisor, UFW, GNU Make.

---

## Current Server State Impact

The current state matters and changes the rollout order:

- `vdsina.com` still has active WireGuard clients, an old `/root/wgdashboard` checkout, and a live `wg0` on UDP `54651`.
- The MVP must not remove or overwrite that existing VPN setup.
- The firewall must keep the legacy WireGuard UDP port open until those clients are intentionally migrated away.
- Admin access for Grafana uses a new WireGuard interface, `wg-admin`, on a new UDP port, `51821`.
- Monitoring files live under `/opt/monitoring`, exporter files under `/opt/vpn-exporters`. Neither path overlaps with `/root/wgdashboard`.
- `vdsina.2gb.com` already runs `wg-easy`; exporter deployment must not touch or restart the existing `wg-easy` compose project.
- Firewall changes are additive and source-IP scoped: exporter and probe ports on `vdsina.2gb.com` are only reachable from `vdsina.com`'s public IPv4.
- UFW is enabled by the `firewall` role **before** any other role on either host. SSH must be in the allow list before UFW is enabled, otherwise the first deployment will sever its own SSH session on `vdsina.com`.

## File Structure

Repo files created or modified by this plan:

- `Makefile` — operator commands wrapping Ansible plus a `download-dashboards` helper.
- `.gitignore` — also exclude `*.key` so locally generated WireGuard private keys are never committed.
- `ansible/ansible.cfg` — inventory, roles path, SSH behaviour.
- `ansible/requirements.yml` — Ansible collections required by the roles.
- `ansible/inventory.example.yml` — sample host inventory and required variables.
- `ansible/playbooks/site.yml`, `monitoring.yml`, `exporters.yml` — entry-point playbooks.
- `ansible/roles/common/tasks/main.yml` — base packages and directories.
- `ansible/roles/docker/tasks/main.yml` — install Docker CE + Compose plugin from the official Docker repo.
- `ansible/roles/firewall/tasks/{main,monitoring_host,exporter_host}.yml` — single source of truth for UFW rules.
- `ansible/roles/admin_wireguard/tasks/main.yml`, `templates/wg-admin.conf.j2` — `wg-admin` interface only (no UFW commands).
- `ansible/roles/monitoring_stack/tasks/main.yml`, `templates/{docker-compose.yml.j2, prometheus.yml.j2}` — monitoring host stack.
- `ansible/roles/vpn_exporters/tasks/main.yml`, `templates/docker-compose.yml.j2` — exporter host stack.
- `monitoring/prometheus/alerts.yml` — static Prometheus rules.
- `monitoring/blackbox/blackbox.yml` — static blackbox module config (shared by both hosts).
- `monitoring/grafana/provisioning/datasources/prometheus.yml` — Prometheus datasource.
- `monitoring/grafana/provisioning/dashboards/default.yml` — dashboard file provider.
- `monitoring/grafana/dashboards/{node-exporter-full.json, cadvisor.json, wireguard.json}` — community dashboards downloaded by `make download-dashboards`.
- `docs/runbook.md` — setup, key generation, deployment, dashboard inventory, alerting behaviour, rollback.

## Task 1: Repository Skeleton

**Files:**
- Create: `Makefile`
- Create: `ansible/ansible.cfg`
- Create: `ansible/requirements.yml`
- Create: `ansible/inventory.example.yml`
- Create: `ansible/playbooks/site.yml`
- Create: `ansible/playbooks/monitoring.yml`
- Create: `ansible/playbooks/exporters.yml`
- Modify: `.gitignore`

- [ ] **Step 1: Create the directory skeleton**

```bash
mkdir -p ansible/playbooks \
  ansible/roles/{common,docker,admin_wireguard,firewall,monitoring_stack,vpn_exporters}/{tasks,templates} \
  monitoring/prometheus monitoring/blackbox \
  monitoring/grafana/provisioning/datasources monitoring/grafana/provisioning/dashboards \
  monitoring/grafana/dashboards \
  docs
```

Expected: command exits with code `0`.

- [ ] **Step 2: Update `.gitignore`**

Replace existing `.gitignore` content with:

```gitignore
ansible/inventory.yml
ansible/group_vars/*/vault.yml
.env
*.retry
.ansible/
.DS_Store
*.key
```

The `*.key` line keeps locally generated WireGuard server/client private keys out of git.

- [ ] **Step 3: Create `ansible/ansible.cfg`**

```ini
[defaults]
inventory = inventory.yml
roles_path = roles
collections_path = .ansible/collections
host_key_checking = True
retry_files_enabled = False
stdout_callback = yaml

[ssh_connection]
pipelining = True
```

`collections_path` keeps `community.general` local to the repo when installed via `make setup`.

- [ ] **Step 4: Create `ansible/requirements.yml`**

```yaml
---
collections:
  - name: community.general
    version: ">=8.0.0"
```

- [ ] **Step 5: Create `ansible/inventory.example.yml`**

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
    vpn_wg_udp_ports:
      - "51820"
    grafana_admin_user: admin
    grafana_admin_password: "replace-with-local-secret"
    prometheus_retention: 15d
    prometheus_retention_size: 2GB
    prometheus_scrape_interval: 30s
    monitoring_base_dir: /opt/monitoring
    exporters_base_dir: /opt/vpn-exporters
    monitoring_repo_dir: "{{ playbook_dir }}/../monitoring"

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

- [ ] **Step 6: Create `ansible/playbooks/monitoring.yml`**

Note the role order: `firewall` runs **before** `admin_wireguard` and `monitoring_stack`, so SSH/admin-WG/legacy-WG ports are open before UFW is enabled.

```yaml
---
- name: Deploy monitoring host
  hosts: monitoring
  become: true
  roles:
    - common
    - docker
    - firewall
    - admin_wireguard
    - monitoring_stack
```

- [ ] **Step 7: Create `ansible/playbooks/exporters.yml`**

```yaml
---
- name: Deploy VPN exporters
  hosts: vpn_exporters
  become: true
  roles:
    - common
    - docker
    - firewall
    - vpn_exporters
```

- [ ] **Step 8: Create `ansible/playbooks/site.yml`**

```yaml
---
- import_playbook: monitoring.yml
- import_playbook: exporters.yml
```

- [ ] **Step 9: Create `Makefile`**

```make
ANSIBLE_DIR := ansible
INVENTORY := $(ANSIBLE_DIR)/inventory.yml
DASHBOARD_DIR := monitoring/grafana/dashboards

.PHONY: setup ping deploy-monitoring deploy-exporters deploy-all status check download-dashboards

setup:
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml -p .ansible/collections

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
```

- [ ] **Step 10: Verify skeleton**

Run:

```bash
find ansible monitoring -maxdepth 4 -type f | sort
```

Expected to include:

```text
ansible/ansible.cfg
ansible/inventory.example.yml
ansible/playbooks/exporters.yml
ansible/playbooks/monitoring.yml
ansible/playbooks/site.yml
ansible/requirements.yml
```

- [ ] **Step 11: Commit**

```bash
git add Makefile .gitignore ansible monitoring docs
git commit -m "Add Ansible project skeleton"
```

## Task 2: Common And Docker Roles

**Files:**
- Create: `ansible/roles/common/tasks/main.yml`
- Create: `ansible/roles/docker/tasks/main.yml`

- [ ] **Step 1: Install the `community.general` collection locally**

Run:

```bash
make setup
```

Expected: `community.general` is downloaded into `ansible/.ansible/collections`.

- [ ] **Step 2: Create `ansible/roles/common/tasks/main.yml`**

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
  when: monitoring_base_dir is defined and 'monitoring' in group_names

- name: Create exporters base directory when configured
  ansible.builtin.file:
    path: "{{ exporters_base_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  when: exporters_base_dir is defined and 'vpn_exporters' in group_names
```

- [ ] **Step 3: Create `ansible/roles/docker/tasks/main.yml`**

This installs Docker CE and the Compose plugin from `download.docker.com`. The Debian-packaged `docker.io` package is not used because it does not ship `docker-compose-plugin`, which the rest of the plan relies on for `docker compose up -d`.

```yaml
---
- name: Ensure /etc/apt/keyrings exists
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"

- name: Detect Debian codename
  ansible.builtin.command: lsb_release -cs
  register: lsb_codename
  changed_when: false

- name: Install Docker apt key
  ansible.builtin.get_url:
    url: https://download.docker.com/linux/debian/gpg
    dest: /etc/apt/keyrings/docker.asc
    mode: "0644"
    force: false

- name: Add Docker apt repository
  ansible.builtin.apt_repository:
    repo: "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian {{ lsb_codename.stdout }} stable"
    filename: docker
    state: present
    update_cache: true

- name: Install Docker packages
  ansible.builtin.apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin
    state: present

- name: Ensure Docker service is enabled and running
  ansible.builtin.service:
    name: docker
    state: started
    enabled: true
```

If the target hosts run Ubuntu instead of Debian, change the URL fragment from `linux/debian` to `linux/ubuntu` in both the keyring and the repository line.

- [ ] **Step 4: Run syntax check**

Run:

```bash
make check
```

Expected: Ansible reports syntax check success for `playbooks/site.yml`.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/common ansible/roles/docker
git commit -m "Add common and Docker roles"
```

## Task 3: Firewall Role

The firewall role is the only place that touches UFW. It runs before `admin_wireguard` and `monitoring_stack` so that SSH stays open across the first deploy and so that `wg-admin` and exporter ports are open before the services that bind to them start.

**Files:**
- Create: `ansible/roles/firewall/tasks/main.yml`
- Create: `ansible/roles/firewall/tasks/monitoring_host.yml`
- Create: `ansible/roles/firewall/tasks/exporter_host.yml`

- [ ] **Step 1: Create `ansible/roles/firewall/tasks/main.yml`**

```yaml
---
- name: Configure monitoring host firewall
  ansible.builtin.include_tasks: monitoring_host.yml
  when: "'monitoring' in group_names"

- name: Configure exporter host firewall
  ansible.builtin.include_tasks: exporter_host.yml
  when: "'vpn_exporters' in group_names"
```

- [ ] **Step 2: Create `ansible/roles/firewall/tasks/monitoring_host.yml`**

SSH is added before UFW is enabled so the in-flight Ansible session is not cut.

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

- [ ] **Step 3: Create `ansible/roles/firewall/tasks/exporter_host.yml`**

Exporter ports (`9100` node, `8080` cadvisor, `9586` wireguard, `9115` blackbox) are restricted to the monitoring host's public IPv4.

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

- name: Allow blackbox_exporter from monitoring host
  community.general.ufw:
    rule: allow
    from_ip: "{{ monitoring_public_ip }}"
    port: "9115"
    proto: tcp

- name: Keep existing wg-easy UDP ports open
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
    proto: udp
  loop: "{{ vpn_wg_udp_ports | default([]) }}"

- name: Enable UFW on exporter host
  community.general.ufw:
    state: enabled
```

The `vpn_wg_udp_ports` loop mirrors the `legacy_wg_udp_ports` pattern on the monitoring host. Without it, enabling UFW would silently sever every active wg-easy peer the moment this role completes.

- [ ] **Step 4: Run syntax check**

```bash
make check
```

Expected: syntax check succeeds.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/firewall
git commit -m "Add firewall role"
```

## Task 4: Admin WireGuard Role

This role only manages the `wg-admin` interface on the monitoring host. UFW rules for the admin port live in the `firewall` role; this role does not touch UFW.

**Files:**
- Create: `ansible/roles/admin_wireguard/tasks/main.yml`
- Create: `ansible/roles/admin_wireguard/handlers/main.yml`
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

Handlers live in `handlers/main.yml`, not at the bottom of `tasks/main.yml` — Ansible parses tasks files as a flat task list.

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
```

- [ ] **Step 3: Create `ansible/roles/admin_wireguard/handlers/main.yml`**

```yaml
---
- name: Restart admin WireGuard
  ansible.builtin.service:
    name: "wg-quick@{{ admin_wg_interface }}"
    state: restarted
```

- [ ] **Step 4: Run syntax check**

```bash
make check
```

Expected: syntax check succeeds.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/admin_wireguard
git commit -m "Add admin WireGuard role"
```

## Task 5: Static Monitoring Artifacts

These are committed once and copied as-is by the monitoring and exporter roles. No Jinja templating.

**Files:**
- Create: `monitoring/prometheus/alerts.yml`
- Create: `monitoring/blackbox/blackbox.yml`
- Create: `monitoring/grafana/provisioning/datasources/prometheus.yml`
- Create: `monitoring/grafana/provisioning/dashboards/default.yml`
- Create: `monitoring/grafana/dashboards/node-exporter-full.json` (downloaded)
- Create: `monitoring/grafana/dashboards/cadvisor.json` (downloaded)
- Create: `monitoring/grafana/dashboards/wireguard.json` (downloaded)

- [ ] **Step 1: Create `monitoring/prometheus/alerts.yml`**

These thresholds are starting values; tune after one week of operation.

```yaml
groups:
  - name: vpn_monitoring
    interval: 30s
    rules:
      - alert: WireGuardPeerNoHandshake
        expr: time() - wireguard_latest_handshake_seconds > 600
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "WireGuard peer {{ $labels.public_key }} has no handshake for >10m"

      - alert: HighCPU
        expr: 100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100 > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CPU on {{ $labels.instance }} above 90% for 5m"

      - alert: DiskAlmostFull
        expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"}) * 100 > 85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Disk on {{ $labels.instance }} {{ $labels.mountpoint }} above 85%"

      - alert: BlackboxProbeFailed
        expr: probe_success == 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Probe to {{ $labels.instance }} from {{ $labels.probe_origin }} failing"

      - alert: ContainerRestartLoop
        expr: changes(container_start_time_seconds{name!=""}[10m]) > 3
        for: 0s
        labels:
          severity: warning
        annotations:
          summary: "Container {{ $labels.name }} restarted >3 times in 10m"
```

- [ ] **Step 2: Create `monitoring/blackbox/blackbox.yml`**

The same module list runs on both blackbox instances (monitoring and exporter hosts). `http_2xx` is used by the scrape jobs in Task 6.

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
  icmp:
    prober: icmp
    timeout: 5s
```

- [ ] **Step 3: Create `monitoring/grafana/provisioning/datasources/prometheus.yml`**

The UID `prometheus` is what the downloaded dashboards refer to after the `sed` patch in `make download-dashboards`.

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    uid: prometheus
    editable: false
```

- [ ] **Step 4: Create `monitoring/grafana/provisioning/dashboards/default.yml`**

```yaml
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards
```

- [ ] **Step 5: Download community dashboards**

Run:

```bash
make download-dashboards
```

Expected: three files appear in `monitoring/grafana/dashboards/`:

```text
monitoring/grafana/dashboards/cadvisor.json
monitoring/grafana/dashboards/node-exporter-full.json
monitoring/grafana/dashboards/wireguard.json
```

If the pinned revisions (`1860/37`, `14282/1`, `12177/1`) become unavailable, bump the revision in the `Makefile` to the latest stable revision shown on the dashboard's grafana.com page and document the new revision in the runbook.

- [ ] **Step 6: Verify dashboards reference the provisioned datasource**

Run:

```bash
grep -c '"prometheus"' monitoring/grafana/dashboards/*.json
```

Expected: each file reports at least one match (the `${DS_PROMETHEUS}` placeholder was replaced).

- [ ] **Step 7: Commit**

```bash
git add monitoring
git commit -m "Add static monitoring artifacts and community dashboards"
```

## Task 6: Monitoring Stack Role

**Files:**
- Create: `ansible/roles/monitoring_stack/tasks/main.yml`
- Create: `ansible/roles/monitoring_stack/templates/docker-compose.yml.j2`
- Create: `ansible/roles/monitoring_stack/templates/prometheus.yml.j2`

- [ ] **Step 1: Create `ansible/roles/monitoring_stack/templates/docker-compose.yml.j2`**

Prometheus mounts both `prometheus.yml` (rendered per-host) and the static `alerts.yml` and runs with `--rule.file` plus retention size cap. Grafana binds only to the admin VPN address and mounts the `provisioning/` and `dashboards/` directories committed in the repo.

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
      - --storage.tsdb.retention.size={{ prometheus_retention_size }}
      - --web.enable-lifecycle
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro
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
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
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

- [ ] **Step 2: Create `ansible/roles/monitoring_stack/templates/prometheus.yml.j2`**

`rule_files` enables the alerts. The two blackbox jobs (`blackbox_external_from_monitoring` and `blackbox_external_from_vpn`) target the same external sites but route through different blackbox instances; the `probe_origin` label distinguishes them in Grafana and in `BlackboxProbeFailed` alerts.

```yaml
global:
  scrape_interval: {{ prometheus_scrape_interval }}
  evaluation_interval: {{ prometheus_scrape_interval }}

rule_files:
  - /etc/prometheus/alerts.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - prometheus:9090

  - job_name: blackbox_external_from_monitoring
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
      - target_label: probe_origin
        replacement: monitoring

  - job_name: blackbox_external_from_vpn
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
        replacement: "{{ vpn_public_ip }}:9115"
      - target_label: probe_origin
        replacement: vpn

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

- [ ] **Step 3: Create `ansible/roles/monitoring_stack/tasks/main.yml`**

The role reads from `monitoring_repo_dir` (set in inventory to `{{ playbook_dir }}/../monitoring`) and copies the static tree to the host. The `command` task that runs `docker compose up -d` registers its output and uses `changed_when` so re-runs without changes are reported as `ok`, not `changed`.

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
    - "{{ monitoring_base_dir }}/grafana"

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

- name: Copy Prometheus alerts
  ansible.builtin.copy:
    src: "{{ monitoring_repo_dir }}/prometheus/alerts.yml"
    dest: "{{ monitoring_base_dir }}/prometheus/alerts.yml"
    owner: root
    group: root
    mode: "0644"

- name: Copy blackbox config
  ansible.builtin.copy:
    src: "{{ monitoring_repo_dir }}/blackbox/blackbox.yml"
    dest: "{{ monitoring_base_dir }}/blackbox/blackbox.yml"
    owner: root
    group: root
    mode: "0644"

- name: Copy Grafana provisioning
  ansible.builtin.copy:
    src: "{{ monitoring_repo_dir }}/grafana/provisioning/"
    dest: "{{ monitoring_base_dir }}/grafana/provisioning/"
    owner: root
    group: root
    mode: "0644"
    directory_mode: "0755"

- name: Copy Grafana dashboards
  ansible.builtin.copy:
    src: "{{ monitoring_repo_dir }}/grafana/dashboards/"
    dest: "{{ monitoring_base_dir }}/grafana/dashboards/"
    owner: root
    group: root
    mode: "0644"
    directory_mode: "0755"

- name: Start monitoring stack
  ansible.builtin.command:
    cmd: docker compose up -d
    chdir: "{{ monitoring_base_dir }}"
  register: monitoring_compose
  changed_when: "'Started' in monitoring_compose.stdout or 'Created' in monitoring_compose.stdout or 'Recreated' in monitoring_compose.stdout"
```

- [ ] **Step 4: Run syntax check**

```bash
make check
```

Expected: syntax check succeeds.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/monitoring_stack
git commit -m "Add monitoring stack role"
```

## Task 7: VPN Exporters Role

The role brings up the four exporter containers and copies the shared `blackbox.yml` from the repo. It does not touch the existing `wg-easy` compose project.

**Files:**
- Create: `ansible/roles/vpn_exporters/tasks/main.yml`
- Create: `ansible/roles/vpn_exporters/templates/docker-compose.yml.j2`

- [ ] **Step 1: Create `ansible/roles/vpn_exporters/templates/docker-compose.yml.j2`**

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

  blackbox_exporter:
    image: prom/blackbox-exporter:v0.25.0
    container_name: blackbox_exporter
    restart: unless-stopped
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro
    ports:
      - "9115:9115"
```

- [ ] **Step 2: Create `ansible/roles/vpn_exporters/tasks/main.yml`**

```yaml
---
- name: Assert WireGuard interface is configured
  ansible.builtin.assert:
    that:
      - wireguard_interface | length > 0
    fail_msg: "Set wireguard_interface for each vpn_exporters host."

- name: Create exporters directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop:
    - "{{ exporters_base_dir }}"
    - "{{ exporters_base_dir }}/blackbox"

- name: Copy blackbox config
  ansible.builtin.copy:
    src: "{{ monitoring_repo_dir }}/blackbox/blackbox.yml"
    dest: "{{ exporters_base_dir }}/blackbox/blackbox.yml"
    owner: root
    group: root
    mode: "0644"

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
  register: exporters_compose
  changed_when: "'Started' in exporters_compose.stdout or 'Created' in exporters_compose.stdout or 'Recreated' in exporters_compose.stdout"
```

- [ ] **Step 3: Run syntax check**

```bash
make check
```

Expected: syntax check succeeds.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/vpn_exporters
git commit -m "Add VPN exporters role"
```

## Task 8: Runbook

**Files:**
- Create: `docs/runbook.md`

- [ ] **Step 1: Write the runbook**

Create `docs/runbook.md` with the following content:

````markdown
# VPN Monitoring Runbook

## Local prerequisites

Install Ansible (system-wide or in a venv) and the project's Ansible collections:

```bash
python3 -m pip install --user ansible
make setup
```

`make setup` is idempotent and reads `ansible/requirements.yml`.

## Generate admin WireGuard keys

Run on your local machine, not on the server:

```bash
wg genkey | tee wg-admin-server.key | wg pubkey > wg-admin-server.pub
wg genkey | tee wg-admin-client.key | wg pubkey > wg-admin-client.pub
```

In `ansible/inventory.yml` set:

- `admin_wg_private_key` to the contents of `wg-admin-server.key`
- `admin_wg_client_public_key` to the contents of `wg-admin-client.pub`

The `*.key` files are ignored by `.gitignore`. Keep them with your password manager or in an encrypted note.

## Configure inventory

```bash
cp ansible/inventory.example.yml ansible/inventory.yml
$EDITOR ansible/inventory.yml
```

Replace every value that contains `replace-with-`, plus the two sample IPs.

## Trust SSH host keys

Avoid an interactive prompt during the first deploy by adding host keys up front:

```bash
ssh-keyscan -H <vdsina.com IP> <vdsina.2gb.com IP> >> ~/.ssh/known_hosts
```

## Preflight before first deployment

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
- TCP `3000` is not bound by another host process.
- There is enough free memory for Prometheus and Grafana.

On `vdsina.2gb.com`:

```bash
wg show
docker ps
ss -tulpn
```

Confirm:

- Existing `wg-easy` is running.
- Exporter ports `9100`, `8080`, `9586`, and `9115` are free.
- `wireguard_interface` in inventory matches the real WireGuard interface.

## First deployment

```bash
make ping
make check
make deploy-monitoring
make deploy-exporters
make status
```

## Access Grafana

Primary access is through the admin WireGuard tunnel. Connect your client to `wg-admin` and open:

```text
http://10.88.0.1:3000
```

Fallback SSH tunnel if the admin VPN is unreachable:

```bash
ssh -L 3000:127.0.0.1:3000 root@vdsina.com
```

Then open `http://127.0.0.1:3000`.

## Dashboard inventory

The bundled Grafana dashboards are downloaded by `make download-dashboards` and live in `monitoring/grafana/dashboards/`. The `Makefile` pins specific revisions:

| File | grafana.com ID | Revision | Purpose |
| --- | --- | --- | --- |
| `node-exporter-full.json` | 1860 | 37 | VPS health on `vdsina.2gb.com` |
| `cadvisor.json` | 14282 | 1 | Docker container CPU, memory, restarts |
| `wireguard.json` | 12177 | 1 | WireGuard peers, handshakes, RX/TX |

To bump a dashboard revision, change the revision number in the `Makefile`'s `download-dashboards` target, re-run it, commit the new JSON, and re-run `make deploy-monitoring`.

## Alerting behaviour

Alerts are evaluated by Prometheus from `monitoring/prometheus/alerts.yml` and surface in two places:

- Prometheus UI at `http://127.0.0.1:9090/alerts` (via SSH tunnel).
- A Grafana Alert List panel pointed at the `Prometheus` datasource.

The MVP does **not** route alerts anywhere. They are visible only when somebody looks. Telegram or email routing through Alertmanager is a Phase 2 candidate.

## Rollback

Stop monitoring stack on `vdsina.com`:

```bash
cd /opt/monitoring && docker compose down
```

Stop exporters on `vdsina.2gb.com`:

```bash
cd /opt/vpn-exporters && docker compose down
```

Disable admin WireGuard on `vdsina.com`:

```bash
systemctl disable --now wg-quick@wg-admin
```

UFW rules added by Ansible can be listed with `ufw status numbered` and removed individually if needed. The legacy `wg0` port and SSH stay open.
````

- [ ] **Step 2: Commit**

```bash
git add docs/runbook.md
git commit -m "Document deployment runbook"
```

## Task 9: Local Validation

**Files:** No file changes expected.

- [ ] **Step 1: Copy inventory example locally**

```bash
cp ansible/inventory.example.yml ansible/inventory.yml
```

Expected: `ansible/inventory.yml` exists.

- [ ] **Step 2: Verify ignored files**

```bash
git status --short
```

Expected: `ansible/inventory.yml` is not listed. If you generated `*.key` files in the repo root they are also not listed.

- [ ] **Step 3: Run Ansible syntax check**

```bash
make check
```

Expected: syntax check passes. (It does not validate that referenced collections are installed at runtime; `make setup` from Task 2 already covers that.)

- [ ] **Step 4: Verify working tree is clean**

```bash
git status --short
```

Expected: no tracked changes after the previous commits.

## Task 10: First Real Deployment Checkpoint

**Files:** No repository changes expected unless deployment reveals required fixes.

- [ ] **Step 1: Generate admin WireGuard keys**

Follow the "Generate admin WireGuard keys" section of the runbook.

- [ ] **Step 2: Fill local inventory with real values**

Edit `ansible/inventory.yml`:

```yaml
monitoring_public_ip: "<real vdsina.com public IPv4>"
vpn_public_ip: "<real vdsina.2gb.com public IPv4>"
admin_wg_private_key: "<contents of wg-admin-server.key>"
admin_wg_client_public_key: "<contents of wg-admin-client.pub>"
grafana_admin_password: "<strong local password, 12+ chars>"
```

- [ ] **Step 3: Verify SSH connectivity**

```bash
make ping
```

Expected: both hosts return `pong`.

- [ ] **Step 4: Deploy monitoring host**

```bash
make deploy-monitoring
```

Expected:

- Docker CE is installed on `vdsina.com`.
- UFW is enabled with allow rules for SSH (`22/tcp`), `wg-admin` (`51821/udp`), and the legacy `54651/udp`.
- Existing `wg0` and SSH keep working.
- New `wg-admin` is up on UDP `51821`.
- `/opt/monitoring/docker-compose.yml` exists.
- `prometheus`, `grafana`, and `blackbox_exporter` containers are running.

- [ ] **Step 5: Deploy exporter host**

```bash
make deploy-exporters
```

Expected:

- Existing `wg-easy` keeps running.
- UFW is enabled with allow rules for SSH and for ports `9100`, `8080`, `9586`, `9115` from `monitoring_public_ip` only.
- `node_exporter`, `cadvisor`, `wireguard_exporter`, and `blackbox_exporter` containers are running.

- [ ] **Step 6: Check Prometheus targets**

Open Prometheus through the admin VPN or the SSH fallback tunnel:

```bash
ssh -L 9090:127.0.0.1:9090 root@<vdsina.com IP>
```

Browse `http://127.0.0.1:9090/targets`. Expected targets all `UP`:

```text
prometheus
blackbox_external_from_monitoring
blackbox_external_from_vpn
node_vdsina_2g
cadvisor_vdsina_2g
wireguard_vdsina_2g
```

- [ ] **Step 7: Check alerts loaded**

In the Prometheus UI, open `http://127.0.0.1:9090/alerts`. Expected: five rules listed (`WireGuardPeerNoHandshake`, `HighCPU`, `DiskAlmostFull`, `BlackboxProbeFailed`, `ContainerRestartLoop`), each in state `inactive` (not firing) on a healthy system.

- [ ] **Step 8: Check Grafana dashboards loaded**

Open Grafana at `http://10.88.0.1:3000` (via admin VPN) or via the SSH fallback. Expected:

- Login works with the credentials from the inventory.
- Datasource `Prometheus` exists and tests `OK`.
- Dashboards `Node Exporter Full`, `cAdvisor`, and `WireGuard` are listed and render data.

If a dashboard panel shows "No data" or "Datasource not found", confirm the panel's datasource is set to `Prometheus` (uid `prometheus`). Older revisions of dashboard 1860 occasionally need a one-time per-panel datasource fix in the UI.

- [ ] **Step 9: Commit fixes if deployment reveals issues**

If any role needs adjustment based on real-server behaviour:

```bash
git add <changed-files>
git commit -m "Fix monitoring deployment issue"
```
