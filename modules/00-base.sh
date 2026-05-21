#!/usr/bin/env bash
# =============================================================================
# 00-base.sh — System baseline
#
# Purpose:
#   Update system packages, install common dependencies, create the standard
#   directory layout, configure sysctl tuning for network monitoring.
#
# What this module does:
#   - apt update && upgrade
#   - Install common deps: curl, wget, jq, git, build-essential, net-tools,
#     gnupg, apt-transport-https, software-properties-common, python3-pip
#   - Create /opt/st0ne_buntu directory structure
#   - Apply sysctl tuning (ring buffer sizes, conntrack limits, etc.)
#   - Set file descriptor limits for ES and Suricata
#   - Configure timezone to UTC (forensic consistency)
#
# Idempotent: yes — safe to re-run
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 00-base: not yet implemented"
# TODO: implement
