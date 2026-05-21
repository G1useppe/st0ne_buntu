#!/usr/bin/env bash
# =============================================================================
# 20-suricata.sh — Suricata IDS + Emerging Threats Open
#
# Purpose:
#   Install Suricata from the OISF stable PPA, configure it for the local
#   interface, download the ET Open ruleset, and set up daily updates.
#
# What this module does:
#   - Add OISF stable PPA
#   - Install suricata (suricata-update is bundled in 7+/8+)
#   - Handle the suricata-update package conflict on 22.04
#   - Backup and configure suricata.yaml:
#       * Set HOME_NET and EXTERNAL_NET
#       * Set af-packet interface to $IFACE
#       * Enable community-id: true (for Zeek/Elastic correlation)
#       * Set EVE JSON output (for Filebeat pickup)
#   - Run suricata-update to fetch ET Open rules
#   - Validate config with suricata -T
#   - Enable and start suricata.service
#   - Install daily cron for rule updates + hot reload
#   - Smoke test against testmynids.org
#
# Depends on: 00-base
# Config used: IFACE, HOME_NET
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 20-suricata: not yet implemented"
# TODO: implement
