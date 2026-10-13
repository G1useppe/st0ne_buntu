#!/usr/bin/env bash
# =============================================================================
# 35-arkime.sh — Arkime full packet capture + session analysis
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 35-arkime: starting …"
export DEBIAN_FRONTEND=noninteractive

if [[ "${INSTALL_ARKIME:-Y}" =~ ^[Nn] ]]; then
    info "Arkime install skipped (INSTALL_ARKIME=N in st0ne_buntu.conf)."
    exit 0
fi

ARKIME_VERSION=$(get_version arkime || true)
[[ -z "$ARKIME_VERSION" ]] && ARKIME_VERSION="6.4.0"
ARKIME_PREFIX="/opt/arkime"

# Detect Ubuntu release (e.g., 22.04 -> 2204, 24.04 -> 2404)
UBUNTU_VER="2204"
if [[ -f /etc/os-release ]]; then
    UBUNTU_VER=$(. /etc/os-release && echo "${VERSION_ID//./}")
elif command -v lsb_release &>/dev/null; then
    UBUNTU_VER=$(lsb_release -rs | tr -d '.')
fi

ARKIME_DEB="arkime_${ARKIME_VERSION}-1.ubuntu${UBUNTU_VER}_amd64.deb"
ARKIME_URL="https://github.com/arkime/arkime/releases/download/v${ARKIME_VERSION}/${ARKIME_DEB}"

# ── 1. Download and install Arkime ───────────────────────────────────────────
if [[ -x "${ARKIME_PREFIX}/bin/capture" ]]; then
    info "Arkime already installed."
else
    # Clear any stale/interrupted dpkg or apt states first
    dpkg --configure -a >/dev/null 2>&1 || true
    apt-get --fix-broken install -y -qq >/dev/null 2>&1 || true

    # Enable the Ubuntu 'universe' repository for libyara / Perl dependencies
    info "Ensuring Ubuntu 'universe' repository is enabled …"
    apt-get update -qq
    apt-get install -y -qq software-properties-common >/dev/null 2>&1 || true
    add-apt-repository -y universe >/dev/null 2>&1 || true
    apt-get update -qq

    # Remove any mismatched cached .deb from a previous failed attempt
    rm -f /tmp/arkime_*.deb

    DEB_PATH="/tmp/${ARKIME_DEB}"
    download_if_missing "$ARKIME_URL" "$DEB_PATH"
    chmod 644 "$DEB_PATH"

    info "Installing Arkime ${ARKIME_VERSION} (ubuntu${UBUNTU_VER}) …"
    apt-get install -f -y "$DEB_PATH"
    rm -f "$DEB_PATH"
fi

info "Arkime installed at ${ARKIME_PREFIX}"

# ── 2. Create directories & install required metadata/systemd files ──────────
mkdir -p "${PCAP_DIR}" "${ARKIME_PREFIX}/logs" "${ARKIME_PREFIX}/etc"
chown -R nobody:daemon "${PCAP_DIR}" "${ARKIME_PREFIX}/logs" 2>/dev/null || true
info "PCAP storage: ${PCAP_DIR}"

# Install systemd service files shipped in /opt/arkime/etc/
for svc in arkimecapture.service arkimeviewer.service; do
    if [[ -f "${ARKIME_PREFIX}/etc/${svc}" && ! -f "/etc/systemd/system/${svc}" ]]; then
        cp "${ARKIME_PREFIX}/etc/${svc}" "/etc/systemd/system/${svc}"
    fi
done
systemctl daemon-reload

# Ensure required IANA IPv4 and IEEE OUI files exist so capture does not abort
if [[ ! -s "${ARKIME_PREFIX}/etc/ipv4-address-space.csv" ]]; then
    info "Fetching IANA ipv4-address-space.csv …"
    curl -fsSL "https://www.iana.org/assignments/ipv4-address-space/ipv4-address-space.csv" \
        -o "${ARKIME_PREFIX}/etc/ipv4-address-space.csv" 2>/dev/null || \
        touch "${ARKIME_PREFIX}/etc/ipv4-address-space.csv"
fi

if [[ ! -s "${ARKIME_PREFIX}/etc/oui.txt" ]]; then
    info "Fetching IEEE OUI manufacturer database …"
    curl -fsSL "https://www.wireshark.org/download/automated/data/manuf" \
        -o "${ARKIME_PREFIX}/etc/oui.txt" 2>/dev/null || \
        touch "${ARKIME_PREFIX}/etc/oui.txt"
fi

# Ensure Suricata directory/eve.json is readable by nobody:daemon for suricata.so
if [[ -d /var/log/suricata ]]; then
    chmod 755 /var/log/suricata 2>/dev/null || true
    touch /var/log/suricata/eve.json
    chmod 644 /var/log/suricata/eve.json 2>/dev/null || true
fi

# ── 3. Write config.ini ─────────────────────────────────────────────────────
ARKIME_CONF="${ARKIME_PREFIX}/etc/config.ini"
backup_file "$ARKIME_CONF"

ES_URL="http://${ES_HOST}:${ES_PORT}"

info "Writing Arkime config.ini …"
cat > "$ARKIME_CONF" <<EOF
# st0ne_buntu — Arkime configuration

[default]
elasticsearch=${ES_URL}
interface=${IFACE}
pcapDir=${PCAP_DIR}

# Minimum free disk space to preserve on the volume (in GB)
freeSpaceG=${MIN_FREE_SPACE_GB}

viewPort=${ARKIME_PORT}
passwordSecret=st0ne_buntu_lab
plugins=suricata.so
suricataAlertFile=/var/log/suricata/eve.json
maxPacketsInQueue=300000
packetThreads=2
magicMode=both
compressES=true
dropUser=nobody
dropGroup=daemon
EOF

info "config.ini written."

# ── 4. Check if ES is reachable (with retry loop) ────────────────────────────
info "Checking Elasticsearch connectivity at ${ES_URL} …"
ES_READY=false
for (( i=1; i<=15; i++ )); do
    if curl -sf "${ES_URL}/_cluster/health" >/dev/null 2>&1; then
        ES_READY=true
        break
    fi
    sleep 2
done

if [[ "$ES_READY" == false ]]; then
    warn "Elasticsearch not reachable at ${ES_URL}."
    exit 1
fi

# ── 5. Initialise Arkime ES indices ──────────────────────────────────────────
INDICES_OUT=$(curl -sf "${ES_URL}/_cat/indices/arkime_*" 2>/dev/null || true)
if [[ -n "$INDICES_OUT" ]]; then
    ARKIME_INDEX_EXISTS=$(printf "%s\n" "$INDICES_OUT" | wc -l | tr -d ' ')
else
    ARKIME_INDEX_EXISTS=0
fi

if [[ "$ARKIME_INDEX_EXISTS" -gt 0 ]]; then
    info "Arkime indices already exist in ES. Skipping init."
else
    info "Initialising Arkime database in Elasticsearch …"
    "${ARKIME_PREFIX}/db/db.pl" "${ES_URL}" init <<< "INIT" >/tmp/arkime_db_init.log 2>&1 || true
    tail -n 5 /tmp/arkime_db_init.log || true
    rm -f /tmp/arkime_db_init.log
    info "Database initialised."
fi

# ── 6. Create admin user ────────────────────────────────────────────────────
USER_JSON=$(curl -sf "${ES_URL}/arkime_users/_search?q=userId:admin" 2>/dev/null || true)
ADMIN_EXISTS=0
if [[ -n "$USER_JSON" ]]; then
    ADMIN_EXISTS=$(printf "%s" "$USER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hits',{}).get('total',{}).get('value',0))" 2>/dev/null || echo "0")
fi

if [[ "${ADMIN_EXISTS:-0}" -gt 0 ]]; then
    info "Admin user already exists."
else
    info "Creating Arkime admin user …"
    "${ARKIME_PREFIX}/bin/arkime_add_user.sh" admin "Admin User" st0ne_buntu --admin >/tmp/arkime_user.log 2>&1 || true
    tail -n 3 /tmp/arkime_user.log || true
    rm -f /tmp/arkime_user.log
    info "Admin user created (username: admin, password: st0ne_buntu)."
fi

# ── 7. Enable and start services ────────────────────────────────────────────
info "Starting Arkime viewer …"
systemctl enable arkimeviewer 2>/dev/null || true
systemctl restart arkimeviewer || warn "systemctl restart arkimeviewer returned non-zero."
sleep 3

if service_is_active arkimeviewer; then
    info "Arkime viewer is running on port ${ARKIME_PORT}."
else
    warn "Arkime viewer may not have started. Check /opt/arkime/logs/viewer.log"
fi

if [[ "$IFACE" == "lo" ]]; then
    info "Interface is lo (offline analysis mode)."
else
    # Ensure capture interface exists (e.g., dummy0) before starting arkimecapture
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        modprobe dummy 2>/dev/null || true
        ip link add "$IFACE" type dummy 2>/dev/null || true
        ip link set "$IFACE" up 2>/dev/null || true
    fi
    info "Starting Arkime capture on ${IFACE} …"
    systemctl enable arkimecapture 2>/dev/null || true
    systemctl restart arkimecapture 2>/dev/null || true
fi

# ── 8. Verify viewer responds ───────────────────────────────────────────────
info "Checking Arkime viewer …"
MAX_WAIT=30
WAITED=0
HTTP_CODE="000"

while [[ $WAITED -lt $MAX_WAIT ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${ARKIME_PORT}" 2>/dev/null || true)
    [[ -z "$HTTP_CODE" ]] && HTTP_CODE="000"
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]]; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]]; then
    info "Arkime viewer responding at http://localhost:${ARKIME_PORT}"
else
    warn "Arkime viewer not responding (HTTP ${HTTP_CODE}). Check /opt/arkime/logs/viewer.log"
fi

log "35-arkime completed"
info "Module 35-arkime complete."
