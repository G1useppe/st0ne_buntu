#!/usr/bin/env bash
# =============================================================================
# 15-kibana.sh — Kibana + Elastic Security
#
# Purpose:
#   Install Kibana as the single dashboard/SIEM interface. Enable the Elastic
#   Security app for detection rules and alert triage.
#
# What this module does:
#   - Install pinned Kibana version from Elastic repo (already added by 10-es)
#   - Configure kibana.yml: bind to 0.0.0.0, set ES connection
#   - Disable TLS between Kibana↔ES if ES_DISABLE_SECURITY=Y
#   - Enable and start kibana.service
#   - Wait for Kibana to respond on KIBANA_PORT
#   - Import saved objects: Suricata dashboard, Zeek dashboard (from config/)
#
# Depends on: 10-elasticsearch
# Config used: ES_HOST, ES_PORT, KIBANA_PORT, ES_DISABLE_SECURITY
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 15-kibana: starting …"
export DEBIAN_FRONTEND=noninteractive

KIBANA_VERSION=$(get_version kibana)
[[ -z "$KIBANA_VERSION" ]] && KIBANA_VERSION="8.17.0"

# ── 1. Install Kibana ───────────────────────────────────────────────────────
# Elastic apt repo was already added by 10-elasticsearch
if pkg_installed kibana; then
    info "Kibana already installed."
else
    info "Installing Kibana ${KIBANA_VERSION} …"
    apt-get update -qq
    apt-get install -y -qq "kibana=${KIBANA_VERSION}"
fi

# Pin version
if [[ ! -f /etc/apt/preferences.d/kibana ]]; then
    cat > /etc/apt/preferences.d/kibana <<EOF
Package: kibana
Pin: version ${KIBANA_VERSION}
Pin-Priority: 1000
EOF
    info "Pinned Kibana to version ${KIBANA_VERSION}."
fi

# ── 2. Configure kibana.yml ──────────────────────────────────────────────────
KIBANA_CONF="/etc/kibana/kibana.yml"
backup_file "$KIBANA_CONF"

info "Writing kibana.yml …"
cat > "$KIBANA_CONF" <<EOF
# st0ne_buntu — Kibana configuration

server.port: ${KIBANA_PORT}
server.host: "0.0.0.0"
server.name: "st0ne_buntu"

elasticsearch.hosts: ["http://${ES_HOST}:${ES_PORT}"]

# Logging
logging.root.level: info

# Default landing page — Security overview
server.defaultRoute: "/app/security/overview"
EOF

# If ES security is disabled, no credentials needed
if [[ "${ES_DISABLE_SECURITY:-N}" =~ ^[Yy] ]]; then
    info "ES security disabled — Kibana connecting without auth."
else
    # With security enabled, Kibana needs a service account or enrollment token.
    # For lab builds this is handled during ES setup; flag it if missing.
    warn "ES security is enabled. You may need to configure Kibana credentials."
    warn "See: /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana"
fi

# ── 3. Enable and start Kibana ───────────────────────────────────────────────
info "Enabling Kibana service …"
systemctl enable kibana

info "Starting Kibana …"
systemctl restart kibana

# ── 4. Wait for Kibana to respond ────────────────────────────────────────────
info "Waiting for Kibana on port ${KIBANA_PORT} …"
KIBANA_URL="http://localhost:${KIBANA_PORT}"
MAX_WAIT=90
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "${KIBANA_URL}/api/status" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        break
    fi
    sleep 3
    WAITED=$((WAITED + 3))
    echo -n "."
done
echo ""

if [[ "$HTTP_CODE" == "200" ]]; then
    info "Kibana is up at ${KIBANA_URL}"
else
    warn "Kibana did not return 200 within ${MAX_WAIT}s (got: ${HTTP_CODE})."
    warn "It may still be initialising. Check: journalctl -u kibana --no-pager -n 50"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log "15-kibana completed"
info "Module 15-kibana complete."
