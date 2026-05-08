# VPN Monitoring Design

## Context

There are two current VPS hosts:

- `vdsina.com`: currently an old 1 GB WireGuard VPS. It will become the monitoring host over time.
- `vdsina.2gb.com`: the primary VPN host running `wg-easy` in Docker.

The main operational problem is that the primary VPN sometimes becomes slow or stops loading sites. During those incidents, the monitoring setup should help identify whether the cause is VPS resource pressure, provider/network issues, WireGuard peer problems, Docker/wg-easy issues, or a client-side problem.

The project should also provide a repeatable way to deploy the setup in a few local commands instead of manually configuring servers over SSH.

## Goals

- Run Grafana and Prometheus on `vdsina.com` as a separate monitoring host.
- Run lightweight exporters on `vdsina.2gb.com`.
- Deploy everything through Ansible and Docker Compose.
- Keep deployment reproducible from this repository.
- Avoid CI/CD for the first version; deploy locally through `make` commands.
- Keep Grafana and exporters off the public internet by default.
- Provide enough dashboards to diagnose VPN slowdowns.

## Non-Goals For MVP

- Loki or centralized log storage.
- Telegram alerts.
- Public Grafana over HTTPS.
- GitHub Actions deploy.
- A custom monitoring UI.
- Automatic migration or removal of the old WireGuard service from `vdsina.com`.

## Architecture

```text
local machine / repo
  |
  | Ansible over SSH
  v
vdsina.com
  role: monitoring_host
  Docker Compose:
    - prometheus
    - grafana
    - blackbox_exporter
    - admin WireGuard

vdsina.2gb.com
  role: vpn_exporter_host
  existing:
    - wg-easy
  Docker Compose:
    - node_exporter
    - wireguard_exporter
    - cadvisor
    - blackbox_exporter
```

Prometheus on `vdsina.com` scrapes exporters on `vdsina.2gb.com` by public static IPv4. Firewall rules on `vdsina.2gb.com` allow `node_exporter`, `cadvisor`, `wireguard_exporter`, and `blackbox_exporter` ports only from the public IPv4 of `vdsina.com`.

## Access Model

The primary Grafana access path is a separate admin WireGuard instance on `vdsina.com`.

```text
admin laptop/phone
  |
  | admin WireGuard tunnel
  v
vdsina.com
  Grafana private address/port
  Prometheus private/local-only access
```

This admin VPN must be separate from the primary user VPN on `vdsina.2gb.com`. If the primary VPN is degraded or down, the admin VPN should still allow access to Grafana.

SSH tunnel remains the emergency fallback:

```bash
ssh -L 3000:127.0.0.1:3000 root@vdsina.com
```

The existing HTTPS domain is deferred to Phase 2. If used later, the preferred model is still not to expose Grafana broadly to the internet. Better options are:

- DNS/private hostname usable only while connected to admin VPN.
- Reverse proxy bound to the admin VPN interface.
- Public HTTPS only with additional hardening, explicit auth, and firewall rules.

## Monitoring Components

### On `vdsina.com`

- `prometheus`: stores metrics with a short retention window and evaluates alert rules locally (no Alertmanager in the MVP).
- `grafana`: datasources and dashboards provisioned from the repository.
- `blackbox_exporter`: external connectivity checks from the monitoring host.
- `admin WireGuard`: private operator access to Grafana.

Initial Prometheus settings:

- retention time: 15 days
- retention size: 2 GB (whichever cap fires first)
- scrape interval: 30 seconds
- no Loki/log ingestion

### On `vdsina.2gb.com`

- `node_exporter`: CPU, memory, disk, load, uptime, network throughput, drops/errors.
- `wireguard_exporter`: peer handshakes and traffic counters.
- `cadvisor`: Docker container resource usage for `wg-easy` and related containers.
- `blackbox_exporter`: external probes from the VPN host so connectivity loss can be attributed to the VPN-side uplink instead of the monitoring-side uplink.

## Dashboards

For the MVP, Grafana ships with three community dashboards committed as JSON in `monitoring/grafana/dashboards/` and provisioned automatically through `monitoring/grafana/provisioning/`:

- Node Exporter Full (grafana.com ID `1860`) — VPS health for `vdsina.2gb.com`.
- cAdvisor (grafana.com ID `14282`) — Docker container CPU, memory, restarts for `wg-easy` and exporters.
- WireGuard (grafana.com ID `12177`) — peers, handshakes, RX/TX.

A Grafana datasource for Prometheus is provisioned from `monitoring/grafana/provisioning/datasources/prometheus.yml`. Operators do not click through the UI to wire anything up.

A custom "VPN Triage" dashboard tailored to the diagnostic workflow in this document is a Phase 2 candidate; the community dashboards above cover the building blocks until that exists.

## Alerting

Prometheus evaluates a small set of rules from `monitoring/prometheus/alerts.yml` and surfaces them in its own UI (`/alerts`) and in a Grafana Alert List panel. There is no Alertmanager and no notification routing in the MVP.

Starting rules (thresholds are deliberately rough and meant to be tuned after the first week of operation):

- `WireGuardPeerNoHandshake` — peer without a handshake for more than 10 minutes.
- `HighCPU` — sustained CPU usage above 90% for 5 minutes.
- `DiskAlmostFull` — disk usage above 85%.
- `BlackboxProbeFailed` — any external probe target failing for 2 minutes.
- `ContainerRestartLoop` — a container restarting more than 3 times within 10 minutes.

Notification routing through Alertmanager (Telegram, email) is a Phase 2 candidate.

## Diagnostic Workflow

When the VPN is slow or unavailable:

1. Open Grafana through the admin VPN on `vdsina.com`.
2. Compare external connectivity probes from `vdsina.com` and from `vdsina.2gb.com`. Divergence isolates the problem to one provider's uplink.
3. Check `vdsina.2gb.com` CPU, RAM, load, disk, network drops, and errors.
4. Check Docker and `wg-easy` container health.
5. Check WireGuard peers: latest handshake, active clients, and per-peer traffic.
6. If server metrics and external probes are healthy, treat the issue as likely client-side or client-provider-side.

## Repository Structure

```text
vpn-monitoring/
  ansible/
    inventory.example.yml
    inventory.yml
    playbooks/
      site.yml
      monitoring.yml
      exporters.yml
    roles/
      common/
      docker/
      monitoring_stack/
      vpn_exporters/
      firewall/
      admin_wireguard/
  monitoring/
    prometheus/
      prometheus.yml.j2
      alerts.yml
    grafana/
      provisioning/
      dashboards/
    blackbox/
      blackbox.yml
  exporters/
    docker-compose.yml.j2
  docs/
    runbook.md
  Makefile
  .gitignore
```

`inventory.example.yml`, templates, dashboards, playbooks, roles, and documentation are committed.

The real inventory and secrets are not committed.

## Local Commands

The Makefile should wrap common Ansible commands:

```bash
make setup
make ping
make deploy-monitoring
make deploy-exporters
make deploy-all
make status
```

Expected behavior:

- `make setup`: install Ansible collections required by the playbooks (one-time, idempotent; reads `ansible/requirements.yml`).
- `make ping`: verify SSH/Ansible connectivity.
- `make deploy-monitoring`: configure `vdsina.com` and start the monitoring stack.
- `make deploy-exporters`: configure `vdsina.2gb.com` and start exporters.
- `make deploy-all`: run both deployment paths.
- `make status`: check remote container state and key endpoints.

## Security Rules

- Do not commit real server IPs if the inventory is considered private.
- Do not commit Grafana admin passwords, WireGuard private keys, API tokens, or vault files.
- Exporter ports on `vdsina.2gb.com` must be restricted to `vdsina.com`.
- Grafana should not be publicly exposed in the MVP.
- Prometheus should not be publicly exposed.
- Admin VPN credentials should be treated as sensitive and rotated if leaked.

## Phase 2 Candidates

- Telegram or email alert routing through Alertmanager (rules already exist in MVP).
- Custom "VPN Triage" Grafana dashboard built around the diagnostic workflow in this document.
- Per-peer WireGuard metrics for `wg-easy` (currently blind: `mindflavor/prometheus-wireguard-exporter` with `network_mode: host` cannot see kernel state inside wg-easy's container netns). Likely path: native wg-easy Prometheus endpoint or a wg-easy-aware exporter; either path requires a wg-easy restart and is therefore out of MVP scope.
- Loki for selected logs if 1 GB RAM is no longer a constraint or monitoring moves to a larger host.
- HTTPS reverse proxy for Grafana, preferably still limited to admin VPN.
- CI checks for `ansible-lint`, `yamllint`, and `docker compose config`.
- Manual GitHub Actions deployment after secrets and approvals are designed.
- Monitoring additional VPS hosts.
- Converting `vdsina.com` fully into a dedicated monitoring host by removing old VPN clients and services.
