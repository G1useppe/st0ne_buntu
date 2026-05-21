#!/usr/bin/env bash
# =============================================================================
# 50-kape.sh — KAPE artifact parsers (Linux-side)
#
# Purpose:
#   Set up the Linux-side tooling for working with KAPE triage output.
#   KAPE itself is a Windows tool — this module focuses on parsing and
#   analysing KAPE output on the Ubuntu workstation.
#
# What this module does:
#   - Install .NET runtime (for running KAPE parsers if needed)
#   - Install KAPE-adjacent Linux tools:
#       * Eric Zimmerman tools that have Linux builds (LECmd, MFTECmd, etc.)
#       * python-registry for Windows registry parsing
#       * libesedb for ESE database parsing
#   - Create $KAPE_DIR as standard ingest point for KAPE output
#   - Place helper scripts for common parse workflows
#
# NOTE: KAPE itself cannot be auto-downloaded (requires manual download from
# https://www.kroll.com/en/services/cyber-risk/incident-response-litigation-support/kroll-artifact-parser-extractor-kape).
# This module sets up the ecosystem for analysing KAPE output, not KAPE itself.
#
# Depends on: 00-base
# Config used: KAPE_DIR
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 50-kape: not yet implemented"
# TODO: implement
