# Context for Ansible project: AmneziaWG VPS automation + observability

## Decisions locked 2026-06-05

These override anything below that conflicts:

* **Architecture**: each VPS is a self-contained AmneziaWG appliance with
  *native* exporters (no Docker on AWG hosts).
* **Observability backend**: keep a **central Prometheus + Grafana host** that
  *pulls* from the appliances. Grafana Alloy `remote_write` is an *optional
  alternative*, not the primary path.
* **Repo**: reuse the existing `ansible/` + central `monitoring/` layout already
  in this repo — do NOT scaffold a fresh `awg-vps-automation/` tree. Add the
  AWG roles into the existing `ansible/roles/`.
* **Secure scrape/access path is an open design question** (the old `wg-admin`
  tunnel was removed). Options: UFW source-IP allowlist, SSH tunnel, or Alloy
  push. Pick during design — until then exporters bind to localhost and
  Grafana to `127.0.0.1`.

## Goal

Build an Ansible project that turns a fresh Ubuntu/Debian VPS into a reproducible AmneziaWG VPN appliance with observability.

The project should install and configure:

* AmneziaWG server through `bivlked/amneziawg-installer`
* AWG client management via existing CLI
* node_exporter
* AmneziaWG exporter
* custom per-peer metrics exporter or node_exporter textfile collector
* optional Grafana Alloy / Prometheus remote_write
* backups
* alerts-ready metrics

Do not build a full custom VPN control plane initially. Use the existing `manage_amneziawg.sh` as the source of truth.

---

## Known current setup

Existing manually configured setup:

```text
VPS: AmneziaWG server
Installer: bivlked/amneziawg-installer
Installer version/tag used earlier: v5.15.3
Management script: /root/awg/manage_amneziawg.sh
Interface: awg0
```

Router peer:

```text
Router: GL.iNet GL-MT3600BE / Beryl 7
Router firmware: Admin Panel v4.9.0
Router role: one dedicated AWG peer for whole home network
Preferred peer name: gl_router_home
```

Home network policy:

```text
All LAN/Wi-Fi clients should go through the router AWG tunnel.
Router should use VPN kill switch.
No client should leak through WAN if AWG is down.
```

---

## Important assumptions

AmneziaWG is WireGuard-like but not vanilla WireGuard.

AWG configs may contain obfuscation parameters:

```ini
Jc =
Jmin =
Jmax =
S1 =
S2 =
S3 =
S4 =
H1 =
H2 =
H3 =
H4 =
I1 =
I2 =
I3 =
I4 =
I5 =
```

Do not strip these from generated configs.

One config/private key per device/peer. Never reuse one config across multiple devices.

---

## Repository structure

> Illustrative only. The real repo reuses the existing `ansible/` + central
> `monitoring/` layout (see "Decisions locked"). New AWG roles go into the
> existing `ansible/roles/`; the central Prometheus+Grafana host stays as-is.

```text
awg-vps-automation/
  README.md

  inventory/
    prod.yml

  group_vars/
    awg_servers.yml

  playbooks/
    bootstrap.yml
    clients.yml
    monitoring.yml
    backup.yml

  roles/
    base/
    ssh_hardening/
    firewall/
    amneziawg/
    awg_clients/
    node_exporter/
    amneziawg_exporter/
    awg_peer_exporter/
    grafana_alloy/
    backups/

  templates/
  files/
  scripts/
```

---

## Main Ansible variables

Example `group_vars/awg_servers.yml`:

```yaml
awg_installer_version: "v5.15.3"
awg_installer_url: "https://raw.githubusercontent.com/bivlked/amneziawg-installer/{{ awg_installer_version }}/install_amneziawg_en.sh"

awg_interface: "awg0"
awg_manage_script: "/root/awg/manage_amneziawg.sh"

awg_clients:
  - name: "gl_router_home"
    type: "permanent"
    purpose: "GL.iNet Beryl 7 home router"

  - name: "macbook_pavel"
    type: "permanent"
    purpose: "roaming laptop"

  - name: "iphone_pavel"
    type: "permanent"
    purpose: "roaming phone"

  - name: "guest_example"
    type: "temporary"
    expires: "7d"
    purpose: "temporary guest access"

monitoring:
  node_exporter: true
  amneziawg_exporter: true
  custom_peer_exporter: true
  # NOTE: central Prometheus pulls from these appliances. "localhost-only"
  # therefore requires a scrape path (UFW source-IP / SSH tunnel) — see the
  # "Decisions locked" block at the top. Alloy push is the optional alternative.
  bind_metrics_to_localhost: true
  use_grafana_alloy: false
  prometheus_remote_write_url: ""
```

---

## Role: base

Responsibilities:

* update apt cache
* install base packages:

  * `curl`
  * `wget`
  * `git`
  * `jq`
  * `python3`
  * `python3-venv`
  * `ca-certificates`
  * `gnupg`
  * `unzip`
  * `moreutils` if using `sponge` for atomic textfile writes
* set timezone if needed
* enable unattended security updates if desired

---

## Role: ssh_hardening

Responsibilities:

* optionally disable password auth
* optionally disable root SSH login after bootstrap
* configure allowed SSH users
* install authorized keys
* restart SSH safely

Keep this role conservative. Do not lock out the user.

---

## Role: firewall

Responsibilities:

* allow SSH
* allow AWG UDP port
* allow metrics only from trusted sources or localhost
* deny public access to:

  * Redis
  * exporter ports
  * internal web endpoints

Firewall must not expose:

```text
Redis 6379
AmneziaWG exporter 9351
node_exporter 9100
custom exporter port
```

unless explicitly configured.

---

## Role: amneziawg

Responsibilities:

1. Download pinned installer script.
2. Run installer only once.
3. Verify `manage_amneziawg.sh` exists.
4. Verify `awg0` exists.
5. Verify `awg show awg0` works.
6. Enable relevant systemd service if needed.
7. Run post-install health check.

Idempotent install pattern:

```yaml
- name: Download AmneziaWG installer
  ansible.builtin.get_url:
    url: "{{ awg_installer_url }}"
    dest: /root/install_amneziawg_en.sh
    mode: "0700"

- name: Install AmneziaWG once
  ansible.builtin.command:
    cmd: bash /root/install_amneziawg_en.sh
    creates: "{{ awg_manage_script }}"
```

Health checks:

```sh
sudo test -x /root/awg/manage_amneziawg.sh
sudo awg show awg0
sudo awg show all dump
sudo bash /root/awg/manage_amneziawg.sh check
```

---

## Role: awg_clients

Responsibilities:

* read existing clients
* create missing clients
* never recreate existing clients unless explicitly requested
* support temporary clients with TTL
* fetch generated config artifacts if needed
* avoid logging private config contents

Use:

```sh
sudo bash /root/awg/manage_amneziawg.sh list --json
sudo bash /root/awg/manage_amneziawg.sh add <client_name>
sudo bash /root/awg/manage_amneziawg.sh add <client_name> --expires=<ttl>
sudo bash /root/awg/manage_amneziawg.sh remove <client_name>
```

Security:

```yaml
no_log: true
```

on tasks that may touch:

* `.conf`
* `.vpnuri`
* QR files
* private keys
* server config

Expected generated artifacts per client:

```text
/root/awg/<client>.conf
/root/awg/<client>.png
/root/awg/<client>.vpnuri
```

Do not commit generated client artifacts to git.

---

## Role: node_exporter

Responsibilities:

* install node_exporter
* expose host metrics
* enable textfile collector
* create textfile collector directory, for example:

```text
/var/lib/node_exporter/textfile_collector
```

Example node_exporter args:

```text
--collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

Use node_exporter for:

* CPU
* RAM
* disk
* filesystem
* network
* load average
* service-level custom metrics via textfile collector

---

## Role: amneziawg_exporter

Responsibilities:

* install Redis locally
* configure Redis to listen only on `127.0.0.1`
* install AmneziaWG exporter
* run exporter as systemd service
* bind exporter to `127.0.0.1:9351`
* scrape `awg show all dump`
* expose metrics for connection activity

Recommended env:

```env
AWG_EXPORTER_OPS_MODE=http
AWG_EXPORTER_LISTEN_ADDR=127.0.0.1
AWG_EXPORTER_HTTP_PORT=9351
AWG_EXPORTER_SCRAPE_INTERVAL=60
AWG_EXPORTER_AWG_SHOW_EXEC=awg show all dump
AWG_EXPORTER_REDIS_HOST=127.0.0.1
AWG_EXPORTER_REDIS_PORT=6379
AWG_EXPORTER_REDIS_DB=0
AWG_EXPORTER_EXTRA_LABEL_SERVER=awg-vps
```

Expected metrics:

```text
awg_status
awg_current_online
awg_dau
awg_mau
```

This exporter is useful for high-level online/active user metrics.

It is not enough for detailed per-peer bandwidth analytics.

---

## Role: awg_peer_exporter

Purpose:

Create custom per-peer metrics from:

```sh
sudo awg show awg0 dump
```

or:

```sh
sudo bash /root/awg/manage_amneziawg.sh stats --json
```

Recommended implementation:

* simple Python or Bash script
* cron/systemd timer every 30-60 seconds
* writes Prometheus textfile metrics atomically into node_exporter textfile directory

Desired metrics:

```text
awg_peer_online{peer="gl_router_home"} 1
awg_peer_latest_handshake_timestamp_seconds{peer="gl_router_home"} 1710000000
awg_peer_handshake_age_seconds{peer="gl_router_home"} 12
awg_peer_rx_bytes_total{peer="gl_router_home"} 123456789
awg_peer_tx_bytes_total{peer="gl_router_home"} 987654321
awg_peer_endpoint_changed_total{peer="gl_router_home"} 0
awg_peer_info{peer="gl_router_home",endpoint="x.x.x.x:yyyy",allowed_ips="10.x.x.x/32"} 1
```

Be careful with endpoint labels:

* useful for router peer
* can be high-cardinality for roaming mobile peers
* may need config flag to enable/disable endpoint label

Suggested online logic:

```text
online = latest_handshake_age_seconds < 180
```

For `gl_router_home`, handshake should usually be fresh if `PersistentKeepalive = 25` is set in the router config.

---

## Role: grafana_alloy

Optional.

Use only if metrics should be pushed to external Prometheus/Grafana Cloud/VictoriaMetrics via remote_write.

Responsibilities:

* install Grafana Alloy
* scrape local endpoints:

  * node_exporter
  * amneziawg_exporter
* remote_write to configured endpoint
* add labels:

  * `server`
  * `env`
  * `role`

Local scrape targets:

```text
127.0.0.1:9100
127.0.0.1:9351
```

Do not expose exporters publicly if Alloy is scraping locally.

---

## Role: backups

Responsibilities:

* run `manage_amneziawg.sh backup`
* store backup archive in a known directory
* optionally encrypt backups
* optionally upload to remote storage
* add backup success/failure metric
* add backup systemd timer or cron

Desired custom metrics:

```text
awg_backup_last_success_timestamp_seconds 1710000000
awg_backup_last_status 1
```

Backup tasks should not print secrets.

---

## Monitoring targets

Minimum useful dashboard panels:

```text
AWG status
Current online peers
DAU
MAU
gl_router_home online
gl_router_home handshake age
Per-peer RX bytes
Per-peer TX bytes
Per-peer traffic rate
VPS CPU
VPS RAM
VPS disk
VPS network RX/TX
Backup status
```

Traffic rate is derived in Prometheus from counters:

```promql
rate(awg_peer_rx_bytes_total[5m])
rate(awg_peer_tx_bytes_total[5m])
```

---

## Alerts

Critical:

```text
AWG exporter down
awg_status == 0
gl_router_home offline for more than 3 minutes
VPS disk usage > 85%
VPS memory pressure high
VPS load high for sustained period
Backup failed
```

Important:

```text
No online AWG peers
Router endpoint changed
Large traffic spike by peer
Redis down if amneziawg-exporter depends on it
```

Nice-to-have:

```text
Unknown peer online
Client with expired TTL still online
No backup in last 24 hours
```

---

## Security requirements

* Do not expose Redis publicly.
* Do not expose exporters publicly unless explicitly protected.
* Bind exporter ports to localhost by default.
* Do not log client config contents.
* Do not commit generated configs.
* Use `no_log: true` for sensitive Ansible tasks.
* One config per device.
* Remove leaked configs by removing the peer server-side.
* Use temporary clients for guests.
* Encrypt or securely store backups.
* Keep installer version pinned.

---

## Suggested milestones

### Milestone 1: Bootstrap

```text
Fresh VPS -> AmneziaWG installed -> awg0 works -> health check passes
```

### Milestone 2: Clients

```text
Declared clients are created idempotently.
gl_router_home.conf exists.
Existing clients are not recreated.
```

### Milestone 3: Host observability

```text
node_exporter running.
Host metrics visible.
Textfile collector enabled.
```

### Milestone 4: AWG observability

```text
amneziawg-exporter running on localhost.
awg_status / awg_current_online / awg_dau / awg_mau visible.
```

### Milestone 5: Per-peer metrics

```text
Custom textfile collector emits per-peer handshake and traffic metrics.
Prometheus can calculate per-peer traffic rates.
```

### Milestone 6: Backups and alerts

```text
Backups are automated.
Backup status metric exists.
Alert rules are ready.
```

---

## Definition of done

A fresh VPS can be provisioned with:

```sh
ansible-playbook -i inventory/prod.yml playbooks/bootstrap.yml
ansible-playbook -i inventory/prod.yml playbooks/clients.yml
ansible-playbook -i inventory/prod.yml playbooks/monitoring.yml
ansible-playbook -i inventory/prod.yml playbooks/backup.yml
```

After provisioning:

```text
awg0 is up
manage_amneziawg.sh works
declared clients exist
node_exporter works
amneziawg-exporter works
custom per-peer metrics work
backups work
exporters are not publicly exposed
sensitive configs are not logged or committed
```
