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

info "Module 15-kibana: not yet implemented"
# TODO: implement
