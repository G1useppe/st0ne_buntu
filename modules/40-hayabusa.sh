#!/usr/bin/env bash
# =============================================================================
# 40-hayabusa.sh — Hayabusa Windows event log analyser
#
# Purpose:
#   Install the Hayabusa binary for fast Windows EVTX triage and threat
#   hunting using Sigma-based detection rules.
#
# What this module does:
#   - Download pinned Hayabusa release from GitHub
#   - Extract to /opt/hayabusa/
#   - Symlink binary to /usr/local/bin/hayabusa
#   - Download/update built-in Sigma rules (hayabusa update-rules)
#   - Create wrapper script for common workflows:
#       * Scan a directory of EVTX files
#       * Output to JSON (for optional ES ingest)
#       * Output to CSV for spreadsheet analysis
#   - Create $EVTX_DIR as the standard drop point for evidence
#
# Depends on: 00-base
# Config used: EVTX_DIR
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 40-hayabusa: not yet implemented"
# TODO: implement
