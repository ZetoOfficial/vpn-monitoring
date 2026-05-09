# Phase 2: Native wg-easy v15 Metrics

## Context

The MVP shipped a monitoring stack that ostensibly covers WireGuard, but the WireGuard panel in Grafana is empty. Documented in `docs/runbook.md` under "Known limitation: empty WireGuard dashboard": `mindflavor/prometheus-wireguard-exporter` runs `network_mode: host` and reads kernel WireGuard state from the host netns, but `wg-easy` keeps its `wg0` interface inside the container netns. The exporter is up, exposes `# HELP` / `# TYPE` lines, and produces zero data rows. Alert `WireGuardPeerNoHandshake` therefore silently never fires — looks all-clear, is just blind.

wg-easy v15 (released after the MVP was written) ships a native Prometheus endpoint at `/metrics/prometheus` on the same TCP port as the admin UI. Metrics are emitted from inside the wg-easy process, so the netns isolation that breaks mindflavor is irrelevant. Confirmed against the live host `89.124.119.109` (running `ghcr.io/wg-easy/wg-easy:15` manually) and the upstream docs at `docs/content/advanced/metrics/prometheus.md` in the wg-easy repo.

This spec replaces the broken mindflavor-based observability path with native scrape, swaps the WireGuard dashboard for one designed against the new metric names, and removes the Angular-plugin compatibility flag we added as a workaround for the old dashboard.

## Goals

- Replace blind `mindflavor/prometheus-wireguard-exporter` with native `/metrics/prometheus` scrape against any wg-easy v15 host listed in inventory.
- Swap Grafana dashboard `12177` (rev 1, Angular) for `21733` (recommended by upstream wg-easy docs, React-only).
- Drop the `GF_PLUGIN_ANGULAR_SUPPORT_ENABLED` workaround on the monitoring host.
- Rewrite the `WireGuardPeerNoHandshake` alert against the new metric names.
- Make the scrape job conditional on a per-host `wg_easy_metrics_bearer` being set, so hosts that have not been upgraded to v15 yet (e.g. the existing `vdsina.2gb.com`) are skipped silently rather than scraped against a non-existent endpoint.
- Remove the "Known limitation" section from the runbook; add a short runbook for adding a new wg-easy v15 host as a scrape target.

## Non-Goals

- Managing wg-easy itself via Ansible. wg-easy install, upgrade, and configuration remain operator-owned, off-repo. There is no `wg_easy` role.
- Migrating wg-easy v14 → v15 on `vdsina.2gb.com`. The operator handles that out-of-band when ready; this spec only ensures the monitoring side is ready to consume v15 metrics from any host once the operator flips the per-host bearer var.
- Splitting hosts into separate inventory groups (e.g. `vpn_exporters_v15`). All VPN hosts stay in the existing `vpn_exporters` group; v14 vs. v15 is expressed only through the presence of `wg_easy_metrics_bearer`.
- Alertmanager / Telegram / email routing.
- Custom "VPN Triage" dashboard.
- HTTPS / public Grafana.
- IPv6 support for VPN peers.

## Architecture

The monitoring host (`vdsina.com`) is the only thing this spec changes architecturally. It scrapes wg-easy's native `/metrics/prometheus` over the public internet, authenticated with a Bearer token, with UFW source-IP allowlisting on the VPN host. The VPN host's compose project (`/opt/vpn-exporters`) loses the mindflavor exporter container; the rest of the exporter stack (`node_exporter`, `cadvisor`, `blackbox_exporter`) is untouched.

```text
vdsina.com (monitoring host)
  prometheus
    scrape job wg_easy_<host>
      target = <vpn_ip>:51821
      metrics_path = /metrics/prometheus
      authorization = Bearer <wg_easy_metrics_bearer>
        |
        | HTTPS-less HTTP over public internet
        | source-IP allowed by UFW on remote
        v
<vpn host> (e.g. 89.124.119.109)
  wg-easy v15 (operator-owned, NOT Ansible-managed)
    admin UI on TCP 51821
      |
      | "Enable Prometheus" toggle in admin UI → DB flag
      | Bearer token configured in admin UI
      v
    /metrics/prometheus → emits wg-easy native metrics
```

## Per-Host Activation Model

A host is considered "v15 monitoring-ready" when its inventory entry has a non-empty `wg_easy_metrics_bearer`. The Prometheus template checks this and skips hosts where it is empty.

| Host | wg-easy version | `wg_easy_metrics_bearer` | Scrape job rendered |
|---|---|---|---|
| `vdsina.2gb.com` (today) | v14 | empty | no — wg metrics absent, same as current state |
| `vdsina.2gb.com` (after operator's manual v14→v15) | v15 | set | yes — operator pastes bearer into inventory, runs `make deploy-monitoring` |
| `89.124.119.109` (today) | v15 | set on day 1 | yes |

Until a host has a bearer, it is invisible to wg-easy scrape — but its node/cadvisor/blackbox jobs continue normally. This means Phase 2 deployment does not require synchronizing with the v14→v15 host migration; the two flows are decoupled.

## Components

### File changes

| File | Change |
|---|---|
| `monitoring/grafana/dashboards/wireguard.json` | Replace contents: dashboard `12177` (rev 1) → `21733` (revision pinned in `Makefile`). |
| `Makefile` `download-dashboards` target | Replace the `12177/revisions/1` URL with `21733/revisions/<rev>`. Concrete revision selected at implementation time by `curl https://grafana.com/api/dashboards/21733/revisions` and pinning the latest stable. |
| `ansible/roles/monitoring_stack/templates/docker-compose.yml.j2` | Remove the `GF_PLUGIN_ANGULAR_SUPPORT_ENABLED: "true"` env var and the comment block above it. Dashboard 21733 is React-only. |
| `ansible/roles/vpn_exporters/templates/docker-compose.yml.j2` | Delete the `wireguard_exporter` service block (mindflavor). Other services unchanged. |
| `ansible/roles/firewall/tasks/exporter_host.yml` | Replace the "Allow wireguard_exporter from monitoring host" task (port 9586) with "Allow wg-easy admin UI from monitoring host" (port `{{ wg_easy_admin_port }}`, default 51821). |
| `ansible/roles/monitoring_stack/templates/prometheus.yml.j2` | Remove the unconditional `wireguard_<host>` scrape block. Add a new `wg_easy_<host>` scrape block guarded by `{% if hostvars[host].wg_easy_metrics_bearer | default('') | length > 0 %}`. The block uses `metrics_path: /metrics/prometheus` and `authorization: { type: Bearer, credentials: "{{ ... }}" }`. Port from `hostvars[host].wg_easy_admin_port \| default(51821)`. |
| `ansible/inventory.example.yml` | Per-host (under `vpn_exporters` children): add `wg_easy_admin_port: 51821` and `wg_easy_metrics_bearer: ""` with a comment explaining how to populate it. |
| `monitoring/prometheus/alerts.yml` | Rewrite `WireGuardPeerNoHandshake` against the v15 metric name. Exact metric name TBD — see "Discovery step" below. |
| `docs/runbook.md` | Remove the "Known limitation: empty WireGuard dashboard" section. Add a short "Adding a wg-easy v15 host as a scrape target" section. Update the "Dashboard inventory" table row for `wireguard.json`. |

### Inventory variables (per host in `vpn_exporters`)

```yaml
wg_easy_admin_port: 51821    # TCP port wg-easy admin UI binds; same port serves /metrics/prometheus
wg_easy_metrics_bearer: ""   # Bearer token from wg-easy Admin Panel > General > Enable Prometheus.
                             # Empty until the host is on v15 with metrics enabled — scrape job is then skipped.
```

The bearer is treated as a secret, lives in `inventory.yml` (already gitignored), same trust model as `grafana_admin_password`.

### Manual one-shot operator step (per host, when migrating to v15-monitoring)

This step is documented in the runbook, not automated. It is one-shot per host:

1. Open wg-easy admin UI (e.g. `ssh -L 51821:127.0.0.1:51821 root@<host>` then `http://127.0.0.1:51821`).
2. Admin Panel → General → toggle "Enable Prometheus".
3. Set a Bearer Password (long random string) in the same panel.
4. Paste the value into `inventory.yml` under the host as `wg_easy_metrics_bearer`.
5. `make deploy-monitoring` to re-render `prometheus.yml` with the new scrape job.
6. Verify in Grafana → Explore: `up{job="wg_easy_<host>"} == 1`.

### Discovery step (one-shot, before alert rule rewrite)

The exact metric names emitted by wg-easy v15 `/metrics/prometheus` are not in upstream docs. They will be observed once on the live host:

```bash
curl -H 'Authorization: Bearer <token>' http://89.124.119.109:51821/metrics/prometheus | head -50
```

The output drives:
- The new `WireGuardPeerNoHandshake` expression in `alerts.yml` (replacement for `time() - wireguard_latest_handshake_seconds > 600`).
- A sanity check that dashboard 21733 panels match the metric set we observe.

This is part of the implementation, not a separate spike. It runs once during the implementation against `89.124.119.109` after Step 5 of the operator runbook (Enable Prometheus toggle + bearer in inventory).

## Workflow

End-to-end sequence on the operator side after this spec is implemented and merged:

1. Operator picks a wg-easy v15 host (initially `89.124.119.109`).
2. SSH-tunnel to its admin UI; enable Prometheus + set bearer; paste into `inventory.yml`.
3. `make deploy-exporters` — rolls the updated vpn-exporters compose (no mindflavor) and the updated UFW rules (port 51821 allowed from monitoring host instead of 9586). Note: this does *not* touch wg-easy.
4. `make deploy-monitoring` — rolls the new dashboard `21733`, the new Prometheus scrape job, the new alert rule, and the dropped Angular flag.
5. Verify in Grafana: `up{job="wg_easy_*"} == 1`, dashboard 21733 populated, `WireGuardPeerNoHandshake` alert visible in `/alerts`.

For `vdsina.2gb.com`: the operator runs Step 3 immediately (mindflavor deletion is safe — it returns no data anyway) and runs Step 1+2 only after the manual v14→v15 upgrade lands on that host.

## Risks

- **Step 3 recreates the vpn-exporters compose project on every host in `vpn_exporters`.** wg-easy is a separate compose project, untouched. The recreate is one-shot, removes the mindflavor container, restarts node/cadvisor/blackbox. Brief metric gap (~10s) for those exporters.
- **UFW `delete 9586` happens before `allow 51821`.** Order in the task list matters only if the monitoring host is mid-scrape; in practice, scrape failures are recoverable on next interval. Acceptable.
- **Bearer token in `inventory.yml`** — already gitignored; same risk surface as `grafana_admin_password`. No new exposure.
- **Dashboard 21733 is a community dashboard, not maintained by wg-easy team** (they explicitly note this in their docs). If it breaks against future wg-easy versions, the operator pins the working revision. Same model as 12177/14282/1860 today.
- **Metric names from `/metrics/prometheus` may shift between wg-easy minor versions**, breaking the alert rule. Mitigation: pin a specific wg-easy image tag on the host (operator concern, not in this spec) and review the alert rule on each wg-easy bump.
- **Discovery step depends on the operator completing the manual "Enable Prometheus" UI toggle first.** If the implementation runs the alert rewrite before the toggle is on, `curl` returns `400 Metrics not enabled` and the step fails loudly — no silent damage.

## Rollback

Atomic via git: `git revert <commit> && make deploy-monitoring && make deploy-exporters`. This restores:
- `monitoring/grafana/dashboards/wireguard.json` to dashboard 12177.
- `Makefile download-dashboards` URLs.
- `GF_PLUGIN_ANGULAR_SUPPORT_ENABLED` env on Grafana.
- mindflavor `wireguard_exporter` block in vpn-exporters compose.
- UFW rule on port 9586 (re-added), UFW rule on 51821 (removed).
- Old `wireguard_<host>` scrape job and old `WireGuardPeerNoHandshake` rule.
- Inventory examples without `wg_easy_*` vars.

The bearer token in the operator's actual `inventory.yml` is left as-is — it does no harm in the rolled-back template (rendering skips it).

wg-easy on every host is unaffected by rollback. No client-visible disruption either way.

## Repository Structure Impact

No new directories. No new roles. No new playbooks. No new Make targets. Six files modified, one example file modified, one doc file modified. This is intentionally small — the original framing of the project ("monitoring of existing machines") is preserved; we are not expanding into VPN management.

## Out of Phase 2 Scope (still Phase 2 candidates)

- Alertmanager / Telegram / email routing.
- Custom "VPN Triage" dashboard.
- HTTPS reverse proxy for Grafana.
- CI checks (`ansible-lint`, `yamllint`, `docker compose config`).
- Monitoring additional VPS hosts (the inventory pattern this spec adds — per-host bearer var — already supports adding more `vpn_exporters` hosts; no further work beyond inventory entries).
- Manual GitHub Actions deployment.
- wg-easy v14 → v15 migration on `vdsina.2gb.com` (operator-owned, off-repo).
