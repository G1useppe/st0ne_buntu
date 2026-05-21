#!/usr/bin/env bash
# =============================================================================
# 35-arkime.sh — Arkime full packet capture + session analysis
#
# Purpose:
#   Install Arkime (formerly Moloch) for full PCAP capture with indexed
#   session metadata in Elasticsearch. Provides a web viewer for packet-level
#   investigation.
#
# What this module does:
#   - Download and install pinned Arkime .deb from arkime.com
#   - Run /opt/arkime/bin/Configure (non-interactive):
#       * Set capture interface to $IFACE
#       * Point at local ES (ES_HOST:ES_PORT)
#       * Set PCAP storage dir to $PCAP_DIR
#   - Initialise Arkime ES indices (/opt/arkime/db/db.pl init)
#   - Create admin user for Arkime Viewer
#   - Set PCAP rotation based on PCAP_MAX_GB
#   - Enable and start arkimecapture and arkimeviewer services
#
# Depends on: 10-elasticsearch
# Config used: IFACE, ES_HOST, ES_PORT, PCAP_DIR, PCAP_MAX_GB, ARKIME_PORT
# Idempotent: yes (db.pl init is skipped if indices exist)
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 35-arkime: not yet implemented"
# TODO: implement
