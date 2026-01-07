sudo tee /usr/local/bin/wg-server-setup.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG (override via env) ======
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_ADDR="${WG_ADDR:-10.8.0.1/24}"
WG_NET="${WG_NET:-10.8.0.0/24}"
WG_DIR="/etc/wireguard"

# ====== CHECKS ======
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo wg-server-setup.sh"
  exit 1
fi

DEFAULT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
if [[ -z "${DEFAULT_IF}" ]]; then
  echo "Could not detect default interface. Check: ip route show default"
  exit 1
fi

echo "Using egress interface: ${DEFAULT_IF}"
echo "WireGuard interface: ${WG_IF}  Port: ${WG_PORT}  VPN: ${WG_ADDR}"

# ====== INSTALL ======
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wireguard iptables curl
# Keygen flow is per WireGuard quickstart. :contentReference[oaicite:1]{index=1}

# ====== ENABLE IPv4 FORWARDING ======
cat >/etc/sysctl.d/99-wireguard.conf <<SYS
net.ipv4.ip_forward=1
SYS
sysctl --system >/dev/null

# ====== KEYS ======
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"

if [[ ! -f "${WG_DIR}/server.key" || ! -f "${WG_DIR}/server.pub" ]]; then
  umask 077
  wg genkey > "${WG_DIR}/server.key"
  wg pubkey < "${WG_DIR}/server.key" > "${WG_DIR}/server.pub"
fi

SERVER_PRIV="$(cat "${WG_DIR}/server.key")"
SERVER_PUB="$(cat "${WG_DIR}/server.pub")"

# ====== CONFIG ======
CONF="${WG_DIR}/${WG_IF}.conf"
if [[ -f "${CONF}" ]]; then
  cp "${CONF}" "${CONF}.bak.$(date +%F-%H%M%S)"
  echo "Backed up existing ${CONF}"
fi

cat > "${CONF}" <<CFG
[Interface]
Address = ${WG_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

# Full-tunnel NAT to the VM's egress interface:
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${DEFAULT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${DEFAULT_IF} -j MASQUERADE
CFG

chmod 600 "${CONF}"

# ====== START ======
# wg-quick brings up wg0 from /etc/wireguard/wg0.conf :contentReference[oaicite:2]{index=2}
systemctl enable --now "wg-quick@${WG_IF}"

echo
echo "✅ WireGuard server is up."
echo "Server public key:"
echo "${SERVER_PUB}"
echo
echo "Check status:"
echo "  sudo wg show"
echo
echo "Azure reminder: NIC IP forwarding must be enabled for routing/NAT. :contentReference[oaicite:3]{index=3}"
EOF

sudo chmod +x /usr/local/bin/wg-server-setup.sh
