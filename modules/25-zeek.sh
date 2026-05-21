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
#   - Install pinned Zeek version
#   - Configure node.cfg: set interface to $IFACE
#   - Configure local.zeek:
#       * Enable JSON log output (for Filebeat)
#       * Enable community-id (correlates with Suricata + Elastic)
#       * Load standard protocol analysers
#   - Deploy zeekctl and start workers
#   - Add cron for zeekctl cron (log rotation, crash restart)
#
# Depends on: 00-base
# Config used: IFACE
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 25-zeek: not yet implemented"
# TODO: implement
