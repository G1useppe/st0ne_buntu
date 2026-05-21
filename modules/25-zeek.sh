#!/usr/bin/env bash
# =============================================================================
# 25-zeek.sh — Zeek network analysis framework
#
# Purpose:
#   Install Zeek for deep protocol analysis. Complements Suricata's signature-
#   based detection with behavioural/connection logging.
#
# What this module does:
#   - Add Zeek OBS repository for Ubuntu 22.04
#   - Install zeek-7.0 (LTS line)
#   - Add /opt/zeek/bin to system PATH
#   - Configure local.zeek:
#       * Enable JSON log output (for Filebeat)
#       * Enable community-id (correlates with Suricata + Elastic)
#       * Load standard protocol analysers
#   - Configure node.cfg: set interface to $IFACE
#   - Deploy and start zeekctl
#   - Verify with offline PCAP analysis against demo pcap
#
# Depends on: 00-base
# Config used: IFACE
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 25-zeek: starting …"
export DEBIAN_FRONTEND=noninteractive

ZEEK_PREFIX="/opt/zeek"

# ── 1. Add OBS repository and install Zeek ───────────────────────────────────
if [[ -x "${ZEEK_PREFIX}/bin/zeek" ]]; then
    info "Zeek already installed."
else
    REPO_LIST="/etc/apt/sources.list.d/security:zeek.list"
    KEYRING="/etc/apt/trusted.gpg.d/security_zeek.gpg"

    if [[ ! -f "$REPO_LIST" ]]; then
        info "Adding Zeek OBS repository …"
        echo 'deb http://download.opensuse.org/repositories/security:/zeek/xUbuntu_22.04/ /' \
            | tee "$REPO_LIST" > /dev/null
        curl -fsSL https://download.opensuse.org/repositories/security:zeek/xUbuntu_22.04/Release.key \
            | gpg --dearmor -o "$KEYRING"
        apt-get update -qq
    fi

    info "Installing Zeek 7.0 LTS …"
    apt-get install -y -qq zeek-7.0
fi

ZEEK_VER=$("${ZEEK_PREFIX}/bin/zeek" --version 2>/dev/null | head -1 || echo "unknown")
info "Zeek version: ${ZEEK_VER}"

# ── 2. Add Zeek to system PATH ──────────────────────────────────────────────
PROFILE_SCRIPT="/etc/profile.d/st0ne_buntu-zeek.sh"
if [[ ! -f "$PROFILE_SCRIPT" ]]; then
    info "Adding ${ZEEK_PREFIX}/bin to system PATH …"
    cat > "$PROFILE_SCRIPT" <<EOF
# st0ne_buntu — Zeek PATH
export PATH="${ZEEK_PREFIX}/bin:\$PATH"
EOF
    chmod 644 "$PROFILE_SCRIPT"
fi

# Make zeek available in current session
export PATH="${ZEEK_PREFIX}/bin:$PATH"

# ── 3. Configure local.zeek ─────────────────────────────────────────────────
LOCAL_ZEEK="${ZEEK_PREFIX}/share/zeek/site/local.zeek"
backup_file "$LOCAL_ZEEK"

# Enable JSON logging (for Filebeat ingest)
if ! grep -q 'LogAscii::use_json' "$LOCAL_ZEEK" 2>/dev/null; then
    info "Enabling JSON log output …"
    cat >> "$LOCAL_ZEEK" <<'EOF'

# ── st0ne_buntu additions ────────────────────────────────────────────────────
# JSON log output for Filebeat/Elasticsearch ingest
redef LogAscii::use_json = T;
EOF
fi

# Enable community-id (correlation with Suricata and Elastic)
if ! grep -q 'Community::' "$LOCAL_ZEEK" 2>/dev/null; then
    info "Enabling community-id …"
    cat >> "$LOCAL_ZEEK" <<'EOF'

# Community ID for cross-tool correlation (Suricata, Elastic)
@load policy/protocols/conn/community-id-logging
EOF
fi

# Deploy config overrides from repo if present
ZEEK_CONFIG_DIR="${REPO_DIR}/config/zeek"
if [[ -f "${ZEEK_CONFIG_DIR}/local.zeek" ]]; then
    info "Appending custom local.zeek from repo config …"
    cat "${ZEEK_CONFIG_DIR}/local.zeek" >> "$LOCAL_ZEEK"
fi

# ── 4. Configure node.cfg ───────────────────────────────────────────────────
NODE_CFG="${ZEEK_PREFIX}/etc/node.cfg"
backup_file "$NODE_CFG"

info "Configuring node.cfg with interface ${IFACE} …"
cat > "$NODE_CFG" <<EOF
[zeek]
type=standalone
host=localhost
interface=${IFACE}
EOF

# ── 5. Configure zeekctl.cfg ────────────────────────────────────────────────
ZEEKCTL_CFG="${ZEEK_PREFIX}/etc/zeekctl.cfg"
backup_file "$ZEEKCTL_CFG"

# Set log rotation interval and mail destination
if ! grep -q 'st0ne_buntu' "$ZEEKCTL_CFG" 2>/dev/null; then
    info "Configuring zeekctl.cfg …"
    cat >> "$ZEEKCTL_CFG" <<'EOF'

# st0ne_buntu overrides
LogRotationInterval = 3600
MailTo =
EOF
fi

# ── 6. Deploy and start zeekctl ─────────────────────────────────────────────
info "Running zeekctl deploy …"
"${ZEEK_PREFIX}/bin/zeekctl" install 2>/dev/null || true
"${ZEEK_PREFIX}/bin/zeekctl" deploy 2>/dev/null || true

# Check status
ZEEK_STATUS=$("${ZEEK_PREFIX}/bin/zeekctl" status 2>/dev/null || echo "not running")
info "Zeek status: ${ZEEK_STATUS}"

# If on lo, zeekctl may not start a worker (no traffic). That's fine for
# offline analysis mode — zeek is used with -r for PCAP processing.
if echo "$ZEEK_STATUS" | grep -q "running"; then
    info "Zeek is running."
elif [[ "$IFACE" == "lo" ]]; then
    info "Zeek configured for offline analysis (interface: lo)."
    info "Use: zeek -r <pcap> to process captures."
else
    warn "Zeek may not have started. Check: ${ZEEK_PREFIX}/bin/zeekctl diag"
fi

# ── 7. Add zeekctl cron for log rotation and crash recovery ─────────────────
CRON_FILE="/etc/cron.d/st0ne_buntu-zeek"
if [[ ! -f "$CRON_FILE" ]]; then
    info "Creating zeekctl cron …"
    cat > "$CRON_FILE" <<EOF
# st0ne_buntu — zeekctl maintenance (log rotation, crash restart)
*/5 * * * * root ${ZEEK_PREFIX}/bin/zeekctl cron 2>/dev/null
EOF
    chmod 644 "$CRON_FILE"
fi

# ── 8. Smoke test — offline PCAP analysis ───────────────────────────────────
SMOKE_DIR="/tmp/zeek-smoke-test"
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR"

info "Running smoke test (offline PCAP analysis) …"

# Generate a minimal PCAP with a DNS query for testing
if cmd_exists python3; then
    python3 -c "
import struct, socket

def pcap_header():
    return struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1)

def build_dns_packet():
    # DNS query for example.com (type A)
    dns = (b'\x00\x01'   # transaction ID
           b'\x01\x00'   # flags: standard query
           b'\x00\x01'   # questions: 1
           b'\x00\x00\x00\x00\x00\x00'  # answers, auth, additional: 0
           b'\x07example\x03com\x00'     # query: example.com
           b'\x00\x01'   # type A
           b'\x00\x01')  # class IN
    udp = struct.pack('>HHHH', 12345, 53, 8 + len(dns), 0) + dns
    ip_total = 20 + len(udp)
    ip = struct.pack('>BBHHHBBH4s4s', 0x45, 0, ip_total, 1, 0, 64, 17, 0,
                     socket.inet_aton('10.0.0.1'), socket.inet_aton('8.8.8.8'))
    eth = b'\x00' * 6 + b'\x00' * 6 + struct.pack('>H', 0x0800)
    return eth + ip + udp

def pcap_record(pkt):
    return struct.pack('<IIII', 0, 0, len(pkt), len(pkt))

pkt = build_dns_packet()
with open('${SMOKE_DIR}/test.pcap', 'wb') as f:
    f.write(pcap_header())
    f.write(pcap_record(pkt))
    f.write(pkt)
" 2>/dev/null
fi

if [[ -f "${SMOKE_DIR}/test.pcap" ]]; then
    cd "$SMOKE_DIR"
    "${ZEEK_PREFIX}/bin/zeek" -r test.pcap 2>/dev/null

    if [[ -f "${SMOKE_DIR}/dns.log" || -f "${SMOKE_DIR}/conn.log" ]]; then
        info "Smoke test PASSED — Zeek generated log files from PCAP."
        ls -la "${SMOKE_DIR}"/*.log 2>/dev/null | while read -r line; do
            info "  ${line}"
        done
    else
        warn "Smoke test: no log files generated."
        warn "  Check: ls ${SMOKE_DIR}/"
    fi
else
    warn "Could not generate test PCAP. Skipping smoke test."
fi

rm -rf "$SMOKE_DIR"

# ── Done ─────────────────────────────────────────────────────────────────────
log "25-zeek completed"
info "Module 25-zeek complete."
info "Zeek logs: ${ZEEK_PREFIX}/logs/current/"
info "Offline analysis: zeek -r <pcap>"
