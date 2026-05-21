#!/usr/bin/env bash
# =============================================================================
# st0ne_buntu — install.sh
# Master orchestrator for tooling up a fresh Ubuntu 22.04 LTS VM.
#
# Usage:
#   sudo ./install.sh              # install everything
#   sudo ./install.sh --module 20  # run only module 20-suricata
#   sudo ./install.sh --list       # show available modules
#   sudo ./install.sh --check      # preflight only (no changes)
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/preflight.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
ACTION="install"
TARGET_MODULE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module|-m)  TARGET_MODULE="$2"; shift 2 ;;
        --list|-l)    ACTION="list";      shift   ;;
        --check|-c)   ACTION="check";     shift   ;;
        --help|-h)    ACTION="help";      shift   ;;
        *)            error "Unknown option: $1. Use --help."; ;;
    esac
done

# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "help" ]]; then
    cat <<EOF
st0ne_buntu installer

Usage:
  sudo ./install.sh                  Install all modules in order
  sudo ./install.sh --module 20      Run a single module (by number)
  sudo ./install.sh --list           List available modules
  sudo ./install.sh --check          Preflight checks only

Modules are located in ./modules/ and run in numeric order.
Configuration is read from ./st0ne_buntu.conf (created on first run).
EOF
    exit 0
fi

# ── List modules ─────────────────────────────────────────────────────────────
if [[ "$ACTION" == "list" ]]; then
    echo "Available modules:"
    for mod in "${REPO_DIR}"/modules/[0-9]*.sh; do
        basename "$mod"
    done
    exit 0
fi

# ── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "This script must be run as root (sudo)."

# ── Load or create configuration ─────────────────────────────────────────────
CONF_FILE="${REPO_DIR}/st0ne_buntu.conf"
if [[ ! -f "$CONF_FILE" ]]; then
    info "No configuration found. Running first-time setup …"
    source "${REPO_DIR}/lib/configure.sh"
    generate_config "$CONF_FILE"
fi
source "$CONF_FILE"

# ── Preflight checks ────────────────────────────────────────────────────────
run_preflight "$ACTION"
[[ "$ACTION" == "check" ]] && { info "Preflight passed."; exit 0; }

# ── Execute modules ──────────────────────────────────────────────────────────
for mod in "${REPO_DIR}"/modules/[0-9]*.sh; do
    mod_num=$(basename "$mod" | grep -oP '^\d+')

    # If a specific module was requested, skip others
    if [[ -n "$TARGET_MODULE" && "$mod_num" != "$TARGET_MODULE" ]]; then
        continue
    fi

    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Running: $(basename "$mod")"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if bash "$mod" "$CONF_FILE" "$REPO_DIR"; then
        info "✓ $(basename "$mod") completed."
    else
        error "✗ $(basename "$mod") failed. Fix the issue and re-run:"
        error "  sudo ./install.sh --module ${mod_num}"
    fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "════════════════════════════════════════════════════════════"
info "  st0ne_buntu setup complete"
info ""
info "  Config     : ${CONF_FILE}"
info "  Evidence   : /opt/st0ne_buntu/evidence/"
info "  Kibana     : http://localhost:5601"
info "  Arkime     : http://localhost:8005"
info ""
info "  Run --check to verify all services:  sudo ./install.sh --check"
info "════════════════════════════════════════════════════════════"
