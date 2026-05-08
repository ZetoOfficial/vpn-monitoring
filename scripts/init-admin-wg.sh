#!/usr/bin/env bash
set -euo pipefail

# Generate wg-admin server and client key pairs plus a ready-to-import
# client config, and inject the public side of the keys directly into
# ansible/inventory.yml so the operator never copy-pastes base64 by
# hand.
#
# Idempotent: re-running with an existing .secrets/wg-admin/ keeps the
# keys, regenerates client.conf, and re-applies the inventory injection.
#
# Output (all under .secrets/wg-admin/, gitignored):
#   server.key, server.pub      server identity (server.key goes into
#                               inventory automatically)
#   client.key, client.pub      client identity (client.pub goes into
#                               inventory automatically; client.key is
#                               embedded in client.conf)
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
  awk -F'"' -v key="$1:" '$1 ~ "^[[:space:]]*"key"[[:space:]]*$" {print $2; exit}' "$INVENTORY"
}

read_unquoted() {
  awk -v key="$1:" '{
    sub(/^[[:space:]]+/, "", $0)
    if (index($0, key) == 1) {
      val = substr($0, length(key) + 1)
      sub(/^[[:space:]]+/, "", val)
      print val
      exit
    }
  }' "$INVENTORY"
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

if [[ -f "$OUT_DIR/server.key" && -f "$OUT_DIR/client.key" && -f "$OUT_DIR/server.pub" && -f "$OUT_DIR/client.pub" ]]; then
  echo "Reusing existing keys in $OUT_DIR/."
else
  if [[ -e "$OUT_DIR/server.key" || -e "$OUT_DIR/client.key" ]]; then
    echo "Error: $OUT_DIR has partial key material. Move it aside or delete to start clean." >&2
    exit 1
  fi
  umask 077
  wg genkey | tee "$OUT_DIR/server.key" | wg pubkey > "$OUT_DIR/server.pub"
  wg genkey | tee "$OUT_DIR/client.key" | wg pubkey > "$OUT_DIR/client.pub"
  echo "Generated fresh keys in $OUT_DIR/."
fi

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

# Inject server.key and client.pub into the inventory. Use '|' as the
# sed delimiter — wg base64 keys never contain '|'. Escape '&' in the
# replacement (it would otherwise mean "the matched text").
inject() {
  local field="$1" value="$2"
  local escaped
  escaped=$(printf '%s' "$value" | sed -e 's/[&|]/\\&/g')
  if grep -qE "^[[:space:]]*$field:[[:space:]]" "$INVENTORY"; then
    sed -i.bak -E "s|^([[:space:]]*$field:[[:space:]]*\").*(\".*)$|\1$escaped\2|" "$INVENTORY"
    rm -f "${INVENTORY}.bak"
  else
    echo "Warning: $field not found in $INVENTORY; left as-is." >&2
  fi
}

SERVER_KEY=$(cat "$OUT_DIR/server.key")
CLIENT_PUB=$(cat "$OUT_DIR/client.pub")

inject admin_wg_private_key "$SERVER_KEY"
inject admin_wg_client_public_key "$CLIENT_PUB"

cat <<EOF
Files in $OUT_DIR/:
  server.key   (kept for rotation/audit)
  server.pub   (informational)
  client.key   (embedded in client.conf — do not lose)
  client.pub   (informational)
  client.conf  -> import into your WireGuard client app

Injected into $INVENTORY:
  admin_wg_private_key       <- server.key
  admin_wg_client_public_key <- client.pub

Still TODO in $INVENTORY:
  grafana_admin_password (replace placeholder with a 12+ char password)

Once inventory is complete:
  make check
  make deploy-monitoring
EOF
