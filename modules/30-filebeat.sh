#!/usr/bin/env bash
# =============================================================================
# 30-filebeat.sh — Filebeat Shipper & SIEM Pipelines
#
# Purpose:
#   Install Filebeat, configure modules for Zeek and Suricata, forcefully load
#   ingest pipelines into Elasticsearch, and start the service.
#
# Idempotent: yes — safe to re-run
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

export DEBIAN_FRONTEND=noninteractive

# ── 1. Install Filebeat ──────────────────────────────────────────────────────
info "Updating package index and installing Filebeat..."
apt-get update -qq
apt-get install -y -qq filebeat

# ── 2. Filebeat Module Configuration ─────────────────────────────────────────
info "Enabling Filebeat modules for Suricata and Zeek..."
filebeat modules enable suricata zeek

info "Hardcoding Suricata module configuration..."
cat > /etc/filebeat/modules.d/suricata.yml <<'EOF'
- module: suricata
  eve:
    enabled: true
    var.paths: ["/var/log/suricata/eve.json"]
EOF

info "Hardcoding Zeek module configuration..."
cat > /etc/filebeat/modules.d/zeek.yml <<'EOF'
- module: zeek
  connection:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/conn.log"]
  dns:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/dns.log"]
  http:
    enabled: true
    var.paths: ["/opt/zeek/logs/current/http.log"]
EOF

# ── 3. Initialize Pipelines & Dashboards ─────────────────────────────────────
info "Loading Elasticsearch Ingest Pipelines..."
# The -M flag guarantees the setup command cannot fail due to disabled filesets
filebeat setup --pipelines --modules suricata,zeek -M "suricata.eve.enabled=true"

# ── 4. Service Management ────────────────────────────────────────────────────
info "Enabling Filebeat to start on boot..."
systemctl enable filebeat

info "Restarting Filebeat to apply configurations..."
systemctl restart filebeat

# ── 5. Log setup ─────────────────────────────────────────────────────────────
touch "$LOG_FILE"
log "03-filebeat completed"

info "Module 03-filebeat complete."
