# VPN Monitoring Runbook

## Local prerequisites

Install on your local machine (this is the operator workstation, not the servers):

- **Ansible** — `pipx install ansible` or `brew install ansible`.
- **WireGuard tools** — `brew install wireguard-tools` (for `wg genkey`/`wg pubkey`).
- **WireGuard client app** — for connecting to the admin tunnel from your laptop or phone (macOS: WireGuard from the App Store).

Then install the project's Ansible collections:

```bash
make setup
```

`make setup` is idempotent and reads `ansible/requirements.yml`.

## Configure inventory

```bash
cp ansible/inventory.example.yml ansible/inventory.yml
$EDITOR ansible/inventory.yml
```

Replace every value that contains `replace-with-` and the two sample IPs (`monitoring_public_ip`, `vpn_public_ip`). Leave `admin_wg_private_key` and `admin_wg_client_public_key` for now — the next step fills them.

## Generate admin WireGuard keys and client config

Run on your local machine (never on a server). With `monitoring_public_ip` and `admin_wg_*` already set in `inventory.yml`:

```bash
make wg-admin-init
```

This generates two key pairs and a ready-to-import client config under `.secrets/wg-admin/` (gitignored):

- `server.key`, `server.pub` — server side. Paste `server.key` into `ansible/inventory.yml` as `admin_wg_private_key`.
- `client.key`, `client.pub` — client side. Paste `client.pub` into `ansible/inventory.yml` as `admin_wg_client_public_key`.
- `client.conf` — import this into your WireGuard client app (drag-and-drop in macOS, "Import from file" on phone).

Move all five files into a password manager once the inventory is wired up. The script refuses to overwrite an existing `.secrets/wg-admin/` so you can't accidentally clobber working keys.

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
- `wireguard_interface` in inventory matches the **host-side** interface name from `wg show` on the host (not from inside the wg-easy container) — `wireguard_exporter` runs with `network_mode: host` and reads it from there.
- `vpn_wg_udp_ports` in inventory lists every UDP port wg-easy currently listens on. Read it from `ss -lupn | grep wg`. The default `51820` is wg-easy's out-of-the-box port; if you changed it, update the inventory before the first `make deploy-exporters` or UFW will sever your active peers.

## First deployment

```bash
make ping
make check
make deploy-monitoring
make deploy-exporters
make status
```

## Access Grafana

Primary access is through the admin WireGuard tunnel.

1. Import `.secrets/wg-admin/client.conf` into your WireGuard client (the file already contains the right `Endpoint`, `AllowedIPs`, and keys).
2. Activate the tunnel.
3. Open Grafana:

```text
http://10.88.0.1:3000
```

The Grafana login user/password are whatever you set in the inventory under `grafana_admin_user`/`grafana_admin_password`.

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
- Optionally, a Grafana Alert List panel that you add manually after first login: pick any dashboard → "Add panel" → visualization "Alert list" → datasource `Prometheus`. The MVP does not provision this panel.

The MVP does **not** route alerts anywhere. They are visible only when somebody looks. Telegram or email routing through Alertmanager is a Phase 2 candidate.

## Known limitation: empty WireGuard dashboard

`mindflavor/prometheus-wireguard-exporter` runs with `network_mode: host` and reads kernel WireGuard state from the host's network namespace. When `wg-easy` keeps `wg0` inside its own container netns (the default for the `ghcr.io/wg-easy/wg-easy` image when started with `network_mode: bridge`), the exporter sees zero peers — `up` is `1`, the metric definitions are present, but no `wireguard_*` series ever populate.

Symptoms:

- The "Wireguard" Grafana dashboard renders empty.
- `WireGuardPeerNoHandshake` alert silently never fires — looks "all clear" but is just blind.
- `curl http://<vpn host>:9586/metrics` returns only `# HELP` / `# TYPE` lines, no data rows.

Phase 2 options to fix:

1. Switch to wg-easy's built-in Prometheus endpoint (newer wg-easy versions expose `/metrics` natively); requires editing the wg-easy compose and restarting it.
2. Run the exporter with `network_mode: "container:wg-easy"` plus a host-mode sidecar that proxies port 9586 from the wg-easy netns to the host.
3. Replace mindflavor's exporter with a wg-easy-aware one that reads the wg-easy admin API.

All three are intentionally out of MVP scope because they either touch wg-easy directly or add a brittle proxy layer.

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
