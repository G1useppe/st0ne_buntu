#!/usr/bin/env bash
# =============================================================================
# 60-tcpreplay.sh — Live Security Monitoring Rehearsal Environment
#
# Purpose:
#   Provisions a persistent dummy interface (dummy0) and installs tcpreplay
#   for live network security monitoring rehearsal.
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 60-tcpreplay: starting …"
export DEBIAN_FRONTEND=noninteractive

# ── 1. Install Dependencies ──────────────────────────────────────────────────
info "Installing tcpreplay and wireshark-common (for editcap/capinfos) …"
apt_install tcpreplay wireshark-common

# ── 2. Configure Dummy Kernel Module ─────────────────────────────────────────
info "Configuring the dummy kernel module …"
if ! grep -q "dummy" /etc/modules-load.d/dummy.conf 2>/dev/null; then
    echo "dummy" > /etc/modules-load.d/dummy.conf
fi
modprobe dummy 2>/dev/null || true

# ── 3. Provision Persistent Interface (dummy0) ───────────────────────────────
info "Creating dummy0 systemd service for persistence …"
DUMMY_SERVICE="/etc/systemd/system/dummy-interface.service"

cat > "$DUMMY_SERVICE" <<EOF
[Unit]
Description=Create dummy0 interface for tcpreplay rehearsal
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/ip link add dummy0 type dummy
ExecStart=/sbin/ip link set dev dummy0 mtu 1500
ExecStart=/sbin/ip link set dev dummy0 up
ExecStop=/sbin/ip link delete dummy0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dummy-interface.service
info "Interface dummy0 is up."

# ── 4. Update st0ne_buntu.conf ───────────────────────────────────────────────
if grep -q '^IFACE="lo"' "$CONF_FILE"; then
    info "Updating default IFACE to dummy0 in ${CONF_FILE} …"
    sed -i 's/^IFACE="lo"/IFACE="dummy0"/' "$CONF_FILE"
    
    warn "Interface updated. To bind existing services to dummy0, re-run:"
    warn "  sudo ./install.sh -m 20"
    warn "  sudo ./install.sh -m 25"
    warn "  sudo ./install.sh -m 35"
else
    info "IFACE is currently set to ${IFACE}. Leaving as-is."
fi

log "60-tcpreplay completed"
info "Module 60-tcpreplay complete."