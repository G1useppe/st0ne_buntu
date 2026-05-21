#!/usr/bin/env bash
# =============================================================================
# 30-filebeat.sh — Filebeat log shipper
#
# Purpose:
#   Ship Suricata EVE JSON and Zeek JSON logs into Elasticsearch. Filebeat's
#   built-in modules handle ECS field mapping so Kibana dashboards work
#   out of the box.
#
# What this module does:
#   - Install pinned Filebeat version (Elastic repo already added by 10-es)
#   - Enable the Suricata module:
#       * Point at /var/log/suricata/eve.json
#   - Enable the Zeek module:
#       * Point at /opt/zeek/logs/current/*.log (or detected path)
#   - Configure output.elasticsearch → localhost:9200
#   - Set up Kibana dashboards (filebeat setup --dashboards)
#   - Enable and start filebeat.service
#
# Depends on: 10-elasticsearch, 15-kibana, 20-suricata, 25-zeek
# Config used: ES_HOST, ES_PORT, KIBANA_PORT
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 30-filebeat: not yet implemented"
# TODO: implement
