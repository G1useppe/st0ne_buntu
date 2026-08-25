#!/usr/bin/env bash
# =============================================================================
# 35-arkime.sh — Arkime full packet capture + session analysis
#
# Purpose:
#   Install Arkime for full PCAP capture with indexed session metadata in
#   Elasticsearch. Provides a web viewer for packet-level investigation.
#   Also supports offline PCAP import via arkime-capture --copy.
#
# What this module does:
#   - Download and install Arkime .deb from GitHub releases
#   - Write config.ini (non-interactive, skips Configure script)
#   - Initialise Arkime ES indices (db.pl init)
#   - Create admin user for Arkime Viewer
#   - Set PCAP storage dir and rotation limits
#   - Enable and start arkimecapture and arkimeviewer services
#   - Verify viewer responds on ARKIME_PORT
#
# Depends on: 00-base, 10-elasticsearch
# Config used: IFACE, ES_HOST, ES_PORT, PCAP_DIR, PCAP_MAX_GB, ARKIME_PORT
# Idempotent: yes (db.pl init is skipped if indices exist)
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 35-arkime: starting …"
export DEBIAN_FRONTEND=noninteractive

# ── Check if Arkime install was opted out ────────────────────────────────────
if [[ "${INSTALL_ARKIME:-Y}" =~ ^[Nn] ]]; then
    info "Arkime install skipped (INSTALL_ARKIME=N in st0ne_buntu.conf)."
    info "To install later: set INSTALL_ARKIME=Y in st0ne_buntu.conf and re-run."
    exit 0
fi

ARKIME_VERSION=$(get_version arkime)
[[ -z "$ARKIME_VERSION" ]] && ARKIME_VERSION="6.4.0"
ARKIME_PREFIX="/opt/arkime"
ARKIME_DEB="arkime_${ARKIME_VERSION}-1.ubuntu2204_amd64.deb"
ARKIME_URL="https://github.com/arkime/arkime/releases/download/v${ARKIME_VERSION}/${ARKIME_DEB}"



# ── 2. Create PCAP storage and logs directories ─────────────────────────────
mkdir -p "${PCAP_DIR}"
chown -R nobody:daemon "${PCAP_DIR}" 2>/dev/null || true
mkdir -p "${ARKIME_PREFIX}/logs"
mkdir -p "${ARKIME_PREFIX}/etc" 
info "PCAP storage: ${PCAP_DIR}"

# ── 3. Write config.ini ─────────────────────────────────────────────────────
ARKIME_CONF="${ARKIME_PREFIX}/etc/config.ini"
backup_file "$ARKIME_CONF"

ES_URL="http://${ES_HOST}:${ES_PORT}"

info "Writing Arkime config.ini …"
cat > "$ARKIME_CONF" <<EOF
# st0ne_buntu — Arkime configuration

[default]
# Elasticsearch connection
elasticsearch=${ES_URL}

# Network interface for live capture
interface=${IFACE}

# PCAP storage
pcapDir=${PCAP_DIR}

# Max PCAP disk usage — oldest files rotated out when exceeded
freeSpaceG=${PCAP_MAX_GB}

# Viewer settings
viewPort=${ARKIME_PORT}

# Disable user/password for viewer (lab mode) — set to true for production
passwordSecret=st0ne_buntu_lab

# Plugins
plugins=suricata.so

# Suricata log integration — correlate Arkime sessions with Suricata alerts
suricataAlertFile=/var/log/suricata/eve.json

# Packet settings
maxPacketsInQueue=300000
packetThreads=2

# Session settings
magicMode=both
compressES=true

# Drop privilege
dropUser=nobody
dropGroup=daemon
EOF

info "config.ini written."

# ── 1. Download and install Arkime ───────────────────────────────────────────
if [[ -x "${ARKIME_PREFIX}/bin/capture" ]]; then
    info "Arkime already installed."
else
    DEB_PATH="/tmp/${ARKIME_DEB}"
    download_if_missing "$ARKIME_URL" "$DEB_PATH"

    info "Installing Arkime ${ARKIME_VERSION} …"
    apt-get install -y -qq "$DEB_PATH"
    rm -f "$DEB_PATH"
fi

info "Arkime installed at ${ARKIME_PREFIX}"

# ── 4. Check if ES is reachable ──────────────────────────────────────────────
info "Checking Elasticsearch connectivity …"
if ! curl -sf "${ES_URL}/_cluster/health" > /dev/null 2>&1; then
    warn "Elasticsearch not reachable at ${ES_URL}."
    warn "Ensure module 10-elasticsearch has been run and ES is running."
    warn "Skipping db init — re-run this module after ES is up."
    log "35-arkime: ES not reachable, skipping db init"
    exit 1
fi

# ── 5. Initialise Arkime ES indices ──────────────────────────────────────────
# Check if indices already exist
ARKIME_INDEX_EXISTS=$(curl -sf "${ES_URL}/_cat/indices/arkime_*" 2>/dev/null | wc -l || echo "0")

if [[ "$ARKIME_INDEX_EXISTS" -gt 0 ]]; then
    info "Arkime indices already exist in ES. Skipping init."
else
    info "Initialising Arkime database in Elasticsearch …"
    # db.pl init requires confirmation — pipe "INIT" to it
    echo "INIT" | "${ARKIME_PREFIX}/db/db.pl" "${ES_URL}" init 2>&1 | tail -5
    info "Database initialised."
fi

# ── 6. Create admin user ────────────────────────────────────────────────────
# Check if admin user already exists
ADMIN_EXISTS=$(curl -sf "${ES_URL}/arkime_users/_search?q=userId:admin" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('hits',{}).get('total',{}).get('value',0))" 2>/dev/null || echo "0")

if [[ "$ADMIN_EXISTS" -gt 0 ]]; then
    info "Admin user already exists."
else
    info "Creating Arkime admin user …"
    "${ARKIME_PREFIX}/bin/arkime_add_user.sh" admin "Admin User" st0ne_buntu --admin 2>&1 | tail -3
    info "Admin user created (username: admin, password: st0ne_buntu)."
    warn "⚠  Change the default password: ${ARKIME_PREFIX}/bin/arkime_add_user.sh admin 'Admin User' NEWPASSWORD --admin"
fi

# ── 7. Enable and start services ────────────────────────────────────────────
info "Starting Arkime viewer …"
systemctl enable arkimeviewer 2>/dev/null || true
systemctl restart arkimeviewer
sleep 3

if service_is_active arkimeviewer; then
    info "Arkime viewer is running on port ${ARKIME_PORT}."
else
    warn "Arkime viewer may not have started."
    warn "Check: journalctl -u arkimeviewer --no-pager -n 30"
fi

if [[ "$IFACE" == "lo" ]]; then
    info "Interface is lo (offline analysis mode)."
    info "Arkime live capture NOT enabled — use process-pcaps.sh or:"
    info "  ${ARKIME_PREFIX}/bin/capture --copy -r <pcap> -c ${ARKIME_CONF}"
else
    info "Starting Arkime capture on ${IFACE} …"
    systemctl enable arkimecapture 2>/dev/null || true
    systemctl restart arkimecapture 2>/dev/null || true
    sleep 2

    if service_is_active arkimecapture; then
        info "Arkime capture is running on ${IFACE}."
    else
        warn "Arkime capture may not have started."
        warn "Check: journalctl -u arkimecapture --no-pager -n 30"
    fi
fi

# ── 8. Verify viewer responds ───────────────────────────────────────────────
info "Checking Arkime viewer …"
MAX_WAIT=30
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${ARKIME_PORT}" 2>/dev/null)
    [[ -z "$HTTP_CODE" ]] && HTTP_CODE="000"
# Arkime returns 401 when auth is required, which means it's running
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]]; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]]; then
    info "Arkime viewer responding at http://localhost:${ARKIME_PORT}"
else
    warn "Arkime viewer not responding (HTTP ${HTTP_CODE})."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log "35-arkime completed"
info "Module 35-arkime complete."
info "Viewer:  http://localhost:${ARKIME_PORT} (admin / st0ne_buntu)"
info "Import PCAPs: ${ARKIME_PREFIX}/bin/capture --copy -r <pcap>"
