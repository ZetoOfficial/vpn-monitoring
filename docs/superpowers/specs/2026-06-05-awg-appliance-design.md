# AmneziaWG single-host appliance + observability — design

- **Date:** 2026-06-05
- **Status:** approved-for-planning
- **Scope:** Core (Milestones 1–5, scenario A). Backups, restore-from-backup,
  alerting, and multi-host are explicitly out of scope (separate specs).
- **Brief:** `docs/awg-rebuild-brief.md`

## 1. Goal

One Ansible playbook turns a fresh Ubuntu/Debian VPS into a self-contained
AmneziaWG VPN server with local observability. Headline use case: "вот данные
от сервака → накатили AmneziaWG + обсервабилити с пол-оборота." The motivating
problem is diagnosing "VPN тупит" — so per-peer handshake/traffic visibility is
the point, not SaaS-grade analytics.

## 2. Decisions locked (this session, 2026-06-05)

These override anything conflicting in the brief:

1. **Single host.** No central monitoring host. AmneziaWG and all observability
   live on the same VPS. Split into multi-host later if needed.
2. **Runtime split.** Prometheus + Grafana run in **docker-compose**. Everything
   that must exec `awg show` on the host — AmneziaWG, node_exporter,
   awg_peer_exporter, **amneziawg-exporter, and Redis** — runs **native
   (systemd)**. Rationale: a containerized exporter cannot see the wg interface;
   that is exactly what produced the empty WireGuard dashboard in the old setup.
3. **Metrics set.** node_exporter + awg_peer_exporter (custom per-peer textfile)
   + amneziawg-exporter (+ Redis) for `awg_status`/online/DAU/MAU.
4. **Client model.** Permanent peers declared in inventory and reconciled by
   Ansible (create missing, never recreate). Temporary/guest peers managed by
   hand via `manage_amneziawg.sh`.
5. **Resilience.** Reboot-resilience + persistent Prometheus TSDB only. No
   external dependency (no heartbeat, no remote_write) in this spec.
6. **Repo.** Reuse existing `ansible/` layout; new roles go into
   `ansible/roles/`. Central `monitoring/` artifacts are repurposed for local
   provisioning.

## 3. Topology

```text
                 single VPS (Ubuntu/Debian)
 ┌──────────────────────────────────────────────────────────┐
 │ AmneziaWG (awg0)  ── native, kernel/userspace             │
 │                                                            │
 │ native systemd:                                            │
 │   node_exporter            127.0.0.1:9100  (+ textfile)    │
 │   awg_peer_exporter        → textfile collector dir        │
 │   amneziawg-exporter       127.0.0.1:9351                  │
 │   redis                    127.0.0.1:6379                  │
 │                                                            │
 │ docker-compose (network_mode: host):                      │
 │   prometheus               127.0.0.1:9090  (persistent vol)│
 │   grafana                  127.0.0.1:3000  (persistent vol)│
 └──────────────────────────────────────────────────────────┘
   public (UFW): 22/tcp (SSH) + <AWG>/udp only
   Grafana access: ssh -L 3000:127.0.0.1:3000
```

All exporters, Redis, Prometheus, and Grafana bind to `127.0.0.1`. Nothing in
the observability stack is publicly reachable.

## 4. Data flow

- `node_exporter` exposes host metrics (CPU/RAM/disk/net/load) and reads the
  textfile collector directory.
- `awg_peer_exporter` runs on a systemd timer (30–60s), reads
  `awg show awg0 dump` (or `manage_amneziawg.sh stats --json` — see §10),
  and writes Prometheus metrics **atomically** into the textfile collector dir.
- `amneziawg-exporter` reads `awg show all dump`, uses Redis for online/DAU/MAU
  state, exposes `127.0.0.1:9351`.
- `prometheus` (host network) scrapes `127.0.0.1:9100` and `127.0.0.1:9351`,
  stores to a persistent named volume.
- `grafana` reads the local Prometheus datasource, provisions one starter
  dashboard.

## 5. Roles (under `ansible/roles/`)

| Role | New/Existing | Responsibility |
|---|---|---|
| `common` | existing | base packages, timezone, apt cache |
| `firewall` | rewrite | allow SSH + AWG UDP; UFW enable; everything else localhost |
| `amneziawg` | new | pinned installer (v5.15.3) with `creates:` guard; health-check (`awg show awg0`) |
| `awg_clients` | new | reconcile declarative permanent peers; `no_log` on sensitive tasks; no committed artifacts |
| `node_exporter` | new | native install + textfile collector dir |
| `awg_peer_exporter` | new | per-peer textfile script + systemd timer |
| `amneziawg_exporter` | new | native exporter + Redis, bind 127.0.0.1:9351 |
| `monitoring_stack` | rewrite | docker-compose Prometheus+Grafana (host net), local scrape, provisioned datasource + starter dashboard, persistent volumes |

Playbook `site.yml` order:
`common → firewall → amneziawg → awg_clients → node_exporter →
awg_peer_exporter → amneziawg_exporter → monitoring_stack`.

## 6. Inventory / variables

Single `awg_servers` group (one host for now). Key vars:

```yaml
awg_installer_version: "v5.15.3"
awg_interface: "awg0"
awg_manage_script: "/root/awg/manage_amneziawg.sh"

awg_clients:                      # permanent peers, reconciled by Ansible
  - { name: gl_router_home, purpose: "GL.iNet Beryl 7 home router" }
  - { name: macbook_pavel,  purpose: "roaming laptop" }
  - { name: iphone_pavel,   purpose: "roaming phone" }

awg_peer_exporter_interval: 60
awg_peer_exporter_endpoint_label: true   # off for high-cardinality roaming sets

grafana_admin_user: admin
grafana_admin_password: "<vault/local secret>"
grafana_bind_ip: "127.0.0.1"
prometheus_retention: 15d
prometheus_retention_size: 2GB
prometheus_scrape_interval: 30s
```

Guests/temporary peers are NOT in inventory — added ad-hoc via the script.

## 7. Client model

`awg_clients` role:
1. `manage_amneziawg.sh list --json` → current peers.
2. For each declared permanent peer not present → `add <name>`.
3. Never recreate or remove existing peers.
4. `no_log: true` on tasks touching `.conf`/`.png`/`.vpnuri`/keys.
5. Generated artifacts are never committed; fetch on demand only if requested.

Leaked config remediation = remove the peer server-side. One config per device.

## 8. Observability

- **node_exporter**: host CPU/RAM/disk/filesystem/network/load.
- **awg_peer_exporter** (textfile): `awg_peer_online`,
  `awg_peer_latest_handshake_timestamp_seconds`, `awg_peer_handshake_age_seconds`,
  `awg_peer_rx_bytes_total`, `awg_peer_tx_bytes_total`, `awg_peer_info`
  (endpoint/allowed_ips labels, endpoint label toggleable).
  Online logic: `handshake_age < 180s`.
- **amneziawg-exporter**: `awg_status`, `awg_current_online`, `awg_dau`,
  `awg_mau`.
- **Grafana**: one starter dashboard (host panels + per-peer online/handshake/
  traffic + AWG status). Traffic rate derived in PromQL:
  `rate(awg_peer_rx_bytes_total[5m])`. Access via SSH tunnel only.

## 9. Resilience (and its limits)

In scope:
- All native services `systemd enable`d; docker services `restart: unless-stopped`.
- Prometheus TSDB and Grafana data on **persistent named docker volumes** →
  metric history and dashboards survive reboots and container recreation.

Documented limitations (NOT solved here — by design):
- **Self-monitoring blind spot.** A monitor on the observed host cannot report
  its own total death (host unreachable / VPS hung). You learn about it manually
  (VPN stops working). External heartbeat is deferred until a 2nd host exists.
- **Host-loss data loss.** If the VPS/disk is destroyed, AWG keys, client
  configs, and Prometheus history are lost. Keys/configs are addressed by the
  future backups/restore spec; metric history is intentionally not replicated
  off-host in this phase.

## 10. Assumptions / risks to validate first in implementation

1. **`manage_amneziawg.sh` interface.** The brief assumes `list --json`, `add`,
   `add --expires`, `remove`, `stats --json`, `check`, `backup`. Verify these
   subcommands exist in bivlked/amneziawg-installer v5.15.3. If `--json`/`stats`
   are absent, `awg_clients` and `awg_peer_exporter` fall back to parsing
   `awg show awg0 dump` directly.
2. **Exact amneziawg-exporter project.** Identify the project behind the
   `AWG_EXPORTER_*` env vars and its native install method (binary/Python).
3. **node_exporter**: native (not containerized) so it has host access and the
   textfile collector lives beside it.

## 11. Out of scope (future specs)

- Backups + restore-from-backup ("файлик с бэкапом → накати").
- Alerting / Alertmanager / Telegram routing.
- Multi-host / central stack / external heartbeat / remote_write.
- SSH hardening beyond keeping the operator from being locked out.

## 12. Definition of done

A fresh VPS provisioned with `ansible-playbook -i inventory.yml site.yml`:

- `awg0` is up; `awg show awg0` works; `manage_amneziawg.sh check` passes.
- Declared permanent clients exist; existing ones untouched.
- node_exporter, awg_peer_exporter, amneziawg-exporter, Redis all running native.
- Prometheus scrapes localhost targets; Grafana shows the starter dashboard.
- Only SSH + AWG UDP are publicly reachable; exporters/Redis/Prom/Grafana on
  localhost.
- Metric history and dashboards survive a reboot.
- No client config contents logged or committed.
