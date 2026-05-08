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
ssh-keyscan -H <vdsina.com IP> <vdsina.2g.com IP> >> ~/.ssh/known_hosts
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

On `vdsina.2g.com`:

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
| `node-exporter-full.json` | 1860 | 37 | VPS health on `vdsina.2g.com` |
| `cadvisor.json` | 14282 | 1 | Docker container CPU, memory, restarts |
| `wireguard.json` | 12177 | 1 | WireGuard peers, handshakes, RX/TX |

To bump a dashboard revision, change the revision number in the `Makefile`'s `download-dashboards` target, re-run it, commit the new JSON, and re-run `make deploy-monitoring`.

## Alerting behaviour

Alerts are evaluated by Prometheus from `monitoring/prometheus/alerts.yml` and surface in two places:

- Prometheus UI at `http://127.0.0.1:9090/alerts` (via SSH tunnel).
- Optionally, a Grafana Alert List panel that you add manually after first login: pick any dashboard → "Add panel" → visualization "Alert list" → datasource `Prometheus`. The MVP does not provision this panel.

The MVP does **not** route alerts anywhere. They are visible only when somebody looks. Telegram or email routing through Alertmanager is a Phase 2 candidate.

## Rollback

Stop monitoring stack on `vdsina.com`:

```bash
cd /opt/monitoring && docker compose down
```

Stop exporters on `vdsina.2g.com`:

```bash
cd /opt/vpn-exporters && docker compose down
```

Disable admin WireGuard on `vdsina.com`:

```bash
systemctl disable --now wg-quick@wg-admin
```

UFW rules added by Ansible can be listed with `ufw status numbered` and removed individually if needed. The legacy `wg0` port and SSH stay open.
