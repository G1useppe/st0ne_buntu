#!/usr/bin/env bash
# =============================================================================
# 30-filebeat.sh — Filebeat log shipper
#
# Purpose:
#   Ship Suricata EVE JSON and Zeek logs into Elasticsearch. Filebeat's
#   built-in modules handle ECS field mapping so Kibana dashboards work
#   out of the box.
#
# What this module does:
#   - Install pinned Filebeat version (Elastic repo already added by 10-es)
#   - Configure filebeat.yml: ES output, Kibana connection
#   - Enable and configure the Suricata module (eve.json)
#   - Enable and configure the Zeek module (all log types)
#   - Load Kibana dashboards (filebeat setup --dashboards)
#   - Load index templates and ILM policy
#   - Enable and start filebeat.service
#   - Verify data is reaching Elasticsearch
#
# Depends on: 10-elasticsearch, 15-kibana, 20-suricata, 25-zeek
# Config used: ES_HOST, ES_PORT, KIBANA_PORT
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 30-filebeat: starting …"
export DEBIAN_FRONTEND=noninteractive

FB_VERSION=$(get_version filebeat)
[[ -z "$FB_VERSION" ]] && FB_VERSION="8.17.0"

# ── 1. Install Filebeat ─────────────────────────────────────────────────────
# Elastic repo was already added by 10-elasticsearch
if pkg_installed filebeat; then
    info "Filebeat already installed."
else
    info "Installing Filebeat ${FB_VERSION} …"
    apt-get update -qq
    apt-get install -y -qq "filebeat=${FB_VERSION}"
fi

# Pin version
if [[ ! -f /etc/apt/preferences.d/filebeat ]]; then
    cat > /etc/apt/preferences.d/filebeat <<EOF
Package: filebeat
Pin: version ${FB_VERSION}
Pin-Priority: 1000
EOF
    info "Pinned Filebeat to version ${FB_VERSION}."
fi

# ── 2. Configure filebeat.yml ────────────────────────────────────────────────
FB_CONF="/etc/filebeat/filebeat.yml"
backup_file "$FB_CONF"

info "Writing filebeat.yml …"
cat > "$FB_CONF" <<EOF
# st0ne_buntu — Filebeat configuration

# ── Inputs (handled via modules, not manual inputs) ──────────────────────────
filebeat.config.modules:
  path: \${path.config}/modules.d/*.yml
  reload.enabled: true
  reload.period: 10s

# ── Elasticsearch output ─────────────────────────────────────────────────────
output.elasticsearch:
  hosts: ["http://${ES_HOST}:${ES_PORT}"]
  # ILM policy for log retention
  ilm.enabled: true
  ilm.policy_name: "st0ne_buntu_retention"

# ── Kibana (for dashboard setup) ─────────────────────────────────────────────
setup.kibana:
  host: "http://localhost:${KIBANA_PORT}"

# ── Dashboards ───────────────────────────────────────────────────────────────
setup.dashboards.enabled: true

# ── Template ─────────────────────────────────────────────────────────────────
setup.template.enabled: true
setup.template.name: "filebeat"
setup.template.pattern: "filebeat-*"

# ── Logging ──────────────────────────────────────────────────────────────────
logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
EOF

# ── 3. Enable and configure Suricata module ──────────────────────────────────
info "Enabling Suricata module …"
filebeat modules enable suricata 2>/dev/null || true

SURICATA_MODULE="/etc/filebeat/modules.d/suricata.yml"
cat > "$SURICATA_MODULE" <<EOF
# st0ne_buntu — Filebeat Suricata module
- module: suricata
  eve:
    enabled: true
    var.paths: ["/var/log/suricata/eve.json"]
EOF
info "Suricata module configured → /var/log/suricata/eve.json"

# ── 4. Enable and configure Zeek module ──────────────────────────────────────
info "Enabling Zeek module …"
filebeat modules enable zeek 2>/dev/null || true

ZEEK_LOG_PATH="/opt/zeek/logs/current"
ZEEK_MODULE="/etc/filebeat/modules.d/zeek.yml"

# Zeek module supports multiple log types — enable the key ones
cat > "$ZEEK_MODULE" <<EOF
# st0ne_buntu — Filebeat Zeek module
- module: zeek
  connection:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/conn.log"]
  dns:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/dns.log"]
  http:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/http.log"]
  files:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/files.log"]
  ssl:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/ssl.log"]
  notice:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/notice.log"]
  x509:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/x509.log"]
  ntp:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/ntp.log"]
  smb_files:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/smb_files.log"]
  smb_mapping:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/smb_mapping.log"]
  dce_rpc:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/dce_rpc.log"]
  kerberos:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/kerberos.log"]
  ntlm:
    enabled: true
    var.paths: ["${ZEEK_LOG_PATH}/ntlm.log"]
EOF
info "Zeek module configured → ${ZEEK_LOG_PATH}/*.log"

# ── 5. Disable other default modules ────────────────────────────────────────
# system module is enabled by default — disable it to reduce noise
if [[ -f /etc/filebeat/modules.d/system.yml ]]; then
    filebeat modules disable system 2>/dev/null || true
    info "Disabled default system module."
fi

# ── 6. Test configuration ───────────────────────────────────────────────────
info "Testing Filebeat configuration …"
if filebeat test config -c "$FB_CONF" 2>&1 | tail -3; then
    info "Configuration is valid."
else
    warn "Configuration test reported issues."
fi

if filebeat test output -c "$FB_CONF" 2>&1 | tail -5; then
    info "Elasticsearch output reachable."
else
    warn "Cannot reach Elasticsearch. Check ES is running."
fi

# ── 7. Setup index templates and dashboards ──────────────────────────────────
info "Loading index templates …"
filebeat setup --index-management -c "$FB_CONF" 2>&1 | tail -3 || warn "Index template setup had issues."

info "Loading Kibana dashboards (this may take a minute) …"
filebeat setup --dashboards -c "$FB_CONF" 2>&1 | tail -3 || warn "Dashboard setup had issues."

# ── 8. Enable and start Filebeat ─────────────────────────────────────────────
info "Enabling Filebeat service …"
systemctl enable filebeat

info "(Re)starting Filebeat …"
systemctl restart filebeat
sleep 5

if service_is_active filebeat; then
    info "Filebeat is running."
else
    warn "Filebeat may not have started cleanly."
    warn "Check: journalctl -u filebeat --no-pager -n 50"
fi

# ── 9. Verify data is reaching Elasticsearch ─────────────────────────────────
info "Checking for Filebeat indices in Elasticsearch …"
sleep 10

ES_URL="http://${ES_HOST}:${ES_PORT}"
FB_INDICES=$(curl -sf "${ES_URL}/_cat/indices/filebeat-*?h=index,docs.count" 2>/dev/null || echo "")

if [[ -n "$FB_INDICES" ]]; then
    info "Filebeat indices found in Elasticsearch:"
    echo "$FB_INDICES" | while read -r line; do
        info "  ${line}"
    done
else
    info "No Filebeat indices yet. Data will appear once Suricata/Zeek generate new logs."
    info "For Suricata: new alerts or eve.json entries will be shipped automatically."
    info "For Zeek: logs from zeekctl or 'zeek -r' in ${ZEEK_LOG_PATH}/ will be picked up."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log "30-filebeat completed"
info "Module 30-filebeat complete."
info "Suricata logs → filebeat-* indices in Elasticsearch"
info "Zeek logs → filebeat-* indices in Elasticsearch"
info "Kibana dashboards: http://localhost:${KIBANA_PORT}/app/dashboards"
