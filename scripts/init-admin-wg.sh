#!/usr/bin/env bash
set -euo pipefail

# Generate wg-admin server and client key pairs plus a ready-to-import
# client config. Reads endpoint info from ansible/inventory.yml so the
# operator only has to fill the inventory once.
#
# Output (all under .secrets/wg-admin/, gitignored):
#   server.key, server.pub      paste server.key into inventory.yml as
#                               admin_wg_private_key; server.pub is for
#                               rotation/reference
#   client.key, client.pub      paste client.pub into inventory.yml as
#                               admin_wg_client_public_key
#   client.conf                 import into your WireGuard client app

INVENTORY="${INVENTORY:-ansible/inventory.yml}"
OUT_DIR="${OUT_DIR:-.secrets/wg-admin}"

if ! command -v wg >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Error: 'wg' (wireguard-tools) is not on PATH.

Install it first:
  macOS:  brew install wireguard-tools
  Debian: sudo apt install wireguard-tools
EOF
  exit 1
fi

if [[ ! -f "$INVENTORY" ]]; then
  echo "Error: $INVENTORY not found. Copy ansible/inventory.example.yml first." >&2
  exit 1
fi

read_var() {
  awk -F'"' -v key="$1:" '$1 ~ "^[[:space:]]*"key"$" {print $2; exit}' "$INVENTORY"
}

read_unquoted() {
  awk -v key="$1:" '$1 == key {print $2; exit}' "$INVENTORY"
}

MON_IP=$(read_var monitoring_public_ip)
WG_PORT=$(read_unquoted admin_wg_port)
WG_SERVER_ADDR=$(read_var admin_wg_address)
WG_CLIENT_ALLOWED=$(read_var admin_wg_client_allowed_ip)
WG_SUBNET=$(read_var admin_wg_subnet)

if [[ -z "$MON_IP" || "$MON_IP" == "203.0.113.10" ]]; then
  echo "Error: set monitoring_public_ip in $INVENTORY to your real vdsina.com IP first." >&2
  exit 1
fi

if [[ -z "$WG_PORT" || -z "$WG_SERVER_ADDR" || -z "$WG_CLIENT_ALLOWED" || -z "$WG_SUBNET" ]]; then
  echo "Error: $INVENTORY is missing one of: admin_wg_port, admin_wg_address, admin_wg_client_allowed_ip, admin_wg_subnet." >&2
  echo "Compare against ansible/inventory.example.yml." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

if [[ -e "$OUT_DIR/server.key" || -e "$OUT_DIR/client.key" ]]; then
  echo "Error: $OUT_DIR already contains key material. Move it aside first to avoid overwriting." >&2
  exit 1
fi

umask 077

wg genkey | tee "$OUT_DIR/server.key" | wg pubkey > "$OUT_DIR/server.pub"
wg genkey | tee "$OUT_DIR/client.key" | wg pubkey > "$OUT_DIR/client.pub"

CLIENT_ADDR="${WG_CLIENT_ALLOWED%%/*}"

cat > "$OUT_DIR/client.conf" <<EOF
[Interface]
PrivateKey = $(cat "$OUT_DIR/client.key")
Address = $CLIENT_ADDR/32
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat "$OUT_DIR/server.pub")
Endpoint = $MON_IP:$WG_PORT
AllowedIPs = $WG_SUBNET
PersistentKeepalive = 25
EOF

chmod 600 "$OUT_DIR"/*.key "$OUT_DIR"/client.conf

cat <<EOF
Generated under $OUT_DIR/:
  server.key   -> paste into ansible/inventory.yml as admin_wg_private_key
  client.pub   -> paste into ansible/inventory.yml as admin_wg_client_public_key
  client.conf  -> import into your WireGuard client (macOS app, phone, etc.)

Helpers:
  cat $OUT_DIR/server.key
  cat $OUT_DIR/client.pub

Keep all files in $OUT_DIR/ secret. The directory is gitignored. Move
the keys to a password manager (1Password, Bitwarden) once you've
configured the inventory.
EOF
