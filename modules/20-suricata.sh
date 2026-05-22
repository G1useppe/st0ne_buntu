#!/usr/bin/env bash
# =============================================================================
# 20-suricata.sh — Suricata IDS + Emerging Threats Open (emerging-all.rules)
#
# Purpose:
#   Install Suricata from the OISF stable PPA, configure it for offline PCAP
#   analysis, download the full emerging-all.rules ruleset, and set up daily
#   rule updates.
#
# What this module does:
#   - Add OISF stable PPA
#   - Install suricata (handle suricata-update package conflict on 22.04)
#   - Backup and configure suricata.yaml:
#       * Set HOME_NET and EXTERNAL_NET to "any" (PCAP analysis mode)
#       * Set af-packet interface to $IFACE
#       * Enable community-id: true (for Zeek/Elastic correlation)
#       * Point rule-files at emerging-all.rules
#   - Download emerging-all.rules directly from ET (full ruleset, all enabled)
#   - Validate config with suricata -T
#   - Enable and start suricata.service
#   - Install daily cron for rule updates
#   - Offline PCAP smoke test
#
# Depends on: 00-base
# Config used: IFACE, HOME_NET, EXTERNAL_NET
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 20-suricata: starting …"
export DEBIAN_FRONTEND=noninteractive

# ── 1. Add OISF stable PPA and install Suricata ─────────────────────────────
if pkg_installed suricata; then
    info "Suricata already installed."
else
    info "Adding OISF stable PPA …"
    apt_install software-properties-common
    add-apt-repository -y ppa:oisf/suricata-stable
    apt-get update -qq

    # Handle the suricata-update package conflict on 22.04
    if dpkg -l suricata-update 2>/dev/null | grep -q '^ii'; then
        info "Removing standalone suricata-update (bundled in suricata 7+) …"
        dpkg --remove --force-remove-reinstreq suricata-update 2>/dev/null || true
        apt-get --fix-broken install -y -qq
    fi

    info "Installing Suricata …"
    apt-get install -y -qq suricata
fi

SURICATA_VER=$(suricata -V 2>/dev/null | grep -oP 'version \K[\d.]+' || echo "unknown")
SURICATA_MAJOR_MINOR=$(echo "$SURICATA_VER" | cut -d. -f1-2)
info "Suricata version: ${SURICATA_VER}"

# ── 2. Download emerging-all.rules ──────────────────────────────────────────
RULES_DIR="/var/lib/suricata/rules"
RULES_FILE="${RULES_DIR}/emerging-all.rules"
RULES_URL="https://rules.emergingthreats.net/open/suricata-${SURICATA_MAJOR_MINOR}/emerging-all.rules"

mkdir -p "$RULES_DIR"
info "Downloading emerging-all.rules for Suricata ${SURICATA_MAJOR_MINOR} …"
curl -fsSL "$RULES_URL" -o "$RULES_FILE"
chmod 644 "$RULES_FILE"

RULE_COUNT=$(grep -c '^alert' "$RULES_FILE" 2>/dev/null || echo 0)
info "Rules downloaded: ${RULE_COUNT} active alert rules"

# ── 3. Configure suricata.yaml ───────────────────────────────────────────────
SURICATA_CONF="/etc/suricata/suricata.yaml"
backup_file "$SURICATA_CONF"

# HOME_NET and EXTERNAL_NET — "any" for offline PCAP analysis
info "Setting HOME_NET to ${HOME_NET} …"
sed -i "s|^\(\s*HOME_NET:\s*\)\".*\"|\\1\"${HOME_NET}\"|" "$SURICATA_CONF"

info "Setting EXTERNAL_NET to ${EXTERNAL_NET} …"
sed -i "s|^\(\s*EXTERNAL_NET:\s*\)\".*\"|\\1\"${EXTERNAL_NET}\"|" "$SURICATA_CONF"

# af-packet interface
info "Setting af-packet interface to ${IFACE} …"
sed -i "/^af-packet:/,/^\S/{
    s/^\(\s*- interface:\s*\).*/\1${IFACE}/
}" "$SURICATA_CONF"

# pcap interface (fallback capture method)
sed -i "/^pcap:/,/^\S/{
    s/^\(\s*- interface:\s*\).*/\1${IFACE}/
}" "$SURICATA_CONF"

# Point rule-files at emerging-all.rules
info "Configuring rule-files to use emerging-all.rules …"
sed -i '/^rule-files:/,/^\S/{
    /^rule-files:/!{
        /^\s*-/d
    }
}' "$SURICATA_CONF"
sed -i '/^rule-files:/a\  - emerging-all.rules' "$SURICATA_CONF"

# Set default-rule-path
sed -i "s|^\(default-rule-path:\s*\).*|\1${RULES_DIR}|" "$SURICATA_CONF"

# Enable community-id for cross-tool correlation (Zeek, Elastic)
info "Enabling community-id …"
if grep -q '# *community-id:' "$SURICATA_CONF"; then
    sed -i 's/# *community-id:.*/community-id: true/' "$SURICATA_CONF"
elif grep -q 'community-id:' "$SURICATA_CONF"; then
    sed -i 's/community-id:.*/community-id: true/' "$SURICATA_CONF"
fi

# ── 4. Apply local overrides from config/ ────────────────────────────────────
SURICATA_CONFIG_DIR="${REPO_DIR}/config/suricata"

if [[ -f "${SURICATA_CONFIG_DIR}/threshold.config" ]]; then
    info "Deploying threshold.config …"
    cp "${SURICATA_CONFIG_DIR}/threshold.config" /etc/suricata/threshold.config
fi

# ── 5. Validate configuration ───────────────────────────────────────────────
info "Validating Suricata configuration …"
if suricata -T -c "$SURICATA_CONF" 2>&1 | tail -3; then
    info "Configuration is valid."
else
    warn "Configuration test reported issues. Check output above."
fi

# ── 6. Enable and start Suricata ────────────────────────────────────────────
if [[ "$IFACE" == "lo" ]]; then
    info "Interface is lo (offline analysis mode)."
    info "Suricata live capture NOT enabled — use 'suricata -r <pcap>' or process-pcaps.sh"
    systemctl disable suricata 2>/dev/null || true
    systemctl stop suricata 2>/dev/null || true
else
    info "Enabling Suricata service on ${IFACE} …"
    systemctl enable suricata
    info "(Re)starting Suricata …"
    systemctl restart suricata
    sleep 3

    if service_is_active suricata; then
        info "Suricata is running."
    else
        warn "Suricata may not have started cleanly."
        warn "Check: journalctl -u suricata --no-pager -n 50"
    fi
fi

# ── 7. Daily rule update cron ───────────────────────────────────────────────
CRON_FILE="/etc/cron.daily/st0ne_buntu-suricata-update"
info "Creating daily ET rule update cron …"
cat > "$CRON_FILE" <<EOF
#!/usr/bin/env bash
# Download latest emerging-all.rules and reload Suricata
SURICATA_VER=\$(suricata -V 2>/dev/null | grep -oP 'version \K[\d.]+' || echo "8.0")
MAJOR_MINOR=\$(echo "\$SURICATA_VER" | cut -d. -f1-2)
RULES_URL="https://rules.emergingthreats.net/open/suricata-\${MAJOR_MINOR}/emerging-all.rules"

curl -fsSL "\$RULES_URL" -o "${RULES_DIR}/emerging-all.rules.tmp" && \
    mv "${RULES_DIR}/emerging-all.rules.tmp" "${RULES_DIR}/emerging-all.rules" && \
    chmod 644 "${RULES_DIR}/emerging-all.rules" && \
    suricatasc -c reload-rules 2>/dev/null || \
    systemctl reload suricata 2>/dev/null || true
EOF
chmod 755 "$CRON_FILE"
info "Daily cron installed."

# ── 8. Smoke test (offline PCAP replay) ─────────────────────────────────────
SMOKE_DIR="/tmp/suricata-smoke-test"
SMOKE_PCAP="${SMOKE_DIR}/test.pcap"
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR"

info "Running smoke test (offline PCAP replay) …"

if cmd_exists python3; then
    python3 -c "
import struct, socket

def pcap_header():
    return struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1)

def build_packet():
    payload = b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nuid=0(root) gid=0(root) groups=0(root)\n'
    tcp = struct.pack('>HHIIBBHHH', 80, 12345, 1, 1, 0x50, 0x18, 8192, 0, 0)
    ip_total = 20 + len(tcp) + len(payload)
    ip = struct.pack('>BBHHHBBH4s4s', 0x45, 0, ip_total, 1, 0, 64, 6, 0,
                     socket.inet_aton('93.184.216.34'), socket.inet_aton('10.0.0.1'))
    eth = b'\x00' * 6 + b'\x00' * 6 + struct.pack('>H', 0x0800)
    return eth + ip + tcp + payload

def pcap_record(pkt):
    return struct.pack('<IIII', 0, 0, len(pkt), len(pkt))

pkt = build_packet()
with open('${SMOKE_PCAP}', 'wb') as f:
    f.write(pcap_header())
    f.write(pcap_record(pkt))
    f.write(pkt)
" 2>/dev/null
fi

if [[ -f "$SMOKE_PCAP" ]]; then
    suricata -r "$SMOKE_PCAP" -c "$SURICATA_CONF" -l "$SMOKE_DIR" -k none 2>/dev/null

    if grep -q "GPL ATTACK_RESPONSE\|ET POLICY\|2100498" "${SMOKE_DIR}/fast.log" 2>/dev/null; then
        info "Smoke test PASSED — alert detected in offline replay."
    else
        warn "Smoke test: no alert from offline replay."
        warn "  Check: cat ${SMOKE_DIR}/fast.log"
    fi
else
    warn "Could not generate test PCAP (python3 missing?). Skipping smoke test."
fi

rm -rf "$SMOKE_DIR"

# ── Done ─────────────────────────────────────────────────────────────────────
log "20-suricata completed"
info "Module 20-suricata complete."
