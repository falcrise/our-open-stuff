sudo tee /usr/local/bin/wg-make-client >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WG_IF="${WG_IF:-wg0}"
WG_DIR="/etc/wireguard"
CONF="${WG_DIR}/${WG_IF}.conf"
CLIENTS_DIR="${WG_DIR}/clients"

SERVER_PORT="${SERVER_PORT:-51820}"
DNS="${DNS:-1.1.1.1}"

usage() {
  echo "Usage: sudo SERVER_ENDPOINT=<AZURE_PUBLIC_IP> wg-make-client <client_name> [client_ip]"
  exit 1
}

[[ "${EUID}" -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ $# -ge 1 ]] || usage
[[ -f "${CONF}" ]] || { echo "Missing ${CONF}"; exit 1; }
[[ -f "${WG_DIR}/server.pub" ]] || { echo "Missing ${WG_DIR}/server.pub"; exit 1; }

CLIENT_NAME="$1"
CLIENT_IP="${2:-}"
SERVER_ENDPOINT="${SERVER_ENDPOINT:-}"
[[ -n "${SERVER_ENDPOINT}" ]] || usage

# Refuse to reload if config already contains empty PublicKey lines
if grep -nE '^PublicKey\s*=\s*$' "${CONF}" >/dev/null; then
  echo "ERROR: ${CONF} contains empty 'PublicKey =' lines. Remove broken peers first."
  exit 1
fi

mkdir -p "${CLIENTS_DIR}/${CLIENT_NAME}"
chmod 700 "${CLIENTS_DIR}/${CLIENT_NAME}"

# Generate keys if not present (umask 077 is recommended) :contentReference[oaicite:6]{index=6}
umask 077
KEY="${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.key"
PUB="${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.pub"
if [[ ! -f "${KEY}" || ! -f "${PUB}" ]]; then
  wg genkey > "${KEY}"
  wg pubkey < "${KEY}" > "${PUB}"
fi

CLIENT_PUB="$(tr -d '\r\n' < "${PUB}")"
CLIENT_PRIV="$(tr -d '\r\n' < "${KEY}")"
SERVER_PUB="$(tr -d '\r\n' < "${WG_DIR}/server.pub")"

# Auto-pick next free 10.8.0.X
if [[ -z "${CLIENT_IP}" ]]; then
  CLIENT_IP="$(awk '
    $1=="AllowedIPs"{
      split($3,a,"."); split(a[4],b,"/"); used[b[1]]=1
    }
    END{
      for(i=2;i<=254;i++) if(!used[i]){print "10.8.0."i; exit}
    }' "${CONF}")"
fi

# Remove any existing block tagged for this client
cp "${CONF}" "${CONF}.bak.$(date +%F-%H%M%S)"
perl -0777 -i -pe "s/\\n\\[Peer\\]\\n# client:${CLIENT_NAME}\\nPublicKey[^\\n]*\\nAllowedIPs[^\\n]*\\n//g" "${CONF}"

# Append one clean peer block
printf "\n[Peer]\n# client:%s\nPublicKey = %s\nAllowedIPs = %s/32\n" \
  "${CLIENT_NAME}" "${CLIENT_PUB}" "${CLIENT_IP}" >> "${CONF}"

chmod 600 "${CONF}"

# Hot reload (documented pattern) :contentReference[oaicite:7]{index=7}
wg syncconf "${WG_IF}" <(wg-quick strip "${WG_IF}")

# Client .conf (full tunnel IPv4+IPv6) :contentReference[oaicite:8]{index=8}
CLIENT_CONF="${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.conf"
cat > "${CLIENT_CONF}" <<CFG
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/32
DNS = ${DNS}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${SERVER_ENDPOINT}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CFG

chmod 600 "${CLIENT_CONF}"

echo "✅ Client created: ${CLIENT_NAME}"
echo "   IP: ${CLIENT_IP}"
echo "   Config: ${CLIENT_CONF}"
echo
cat "${CLIENT_CONF}"
EOF

sudo chmod +x /usr/local/bin/wg-make-client
