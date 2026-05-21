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
#   - Create evidence/evtx/ as the standard drop point for evidence
#
# Depends on: 00-base
# Config used: EVTX_DIR
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 40-hayabusa: starting …"

HAYABUSA_VERSION=$(get_version hayabusa)
[[ -z "$HAYABUSA_VERSION" ]] && HAYABUSA_VERSION="3.9.0"
HAYABUSA_PREFIX="/opt/hayabusa"
HAYABUSA_ZIP="hayabusa-${HAYABUSA_VERSION}-lin-x64-musl.zip"
HAYABUSA_URL="https://github.com/Yamato-Security/hayabusa/releases/download/v${HAYABUSA_VERSION}/${HAYABUSA_ZIP}"

# ── 1. Download and install Hayabusa ─────────────────────────────────────────
if [[ -x "${HAYABUSA_PREFIX}/hayabusa" ]]; then
    INSTALLED_VER=$("${HAYABUSA_PREFIX}/hayabusa" --version 2>/dev/null | grep -oP '[\d.]+' || echo "unknown")
    info "Hayabusa already installed (${INSTALLED_VER})."
else
    DL_PATH="/tmp/${HAYABUSA_ZIP}"
    download_if_missing "$HAYABUSA_URL" "$DL_PATH"

    info "Extracting Hayabusa ${HAYABUSA_VERSION} to ${HAYABUSA_PREFIX} …"
    mkdir -p "$HAYABUSA_PREFIX"
    unzip -qo "$DL_PATH" -d "$HAYABUSA_PREFIX"

    # The binary has the version in its filename — rename to plain 'hayabusa'
    if [[ ! -f "${HAYABUSA_PREFIX}/hayabusa" ]]; then
        VERSIONED_BIN=$(find "$HAYABUSA_PREFIX" -maxdepth 1 -type f -name 'hayabusa-*' ! -name '*.zip' | head -1)
        if [[ -n "$VERSIONED_BIN" ]]; then
            mv "$VERSIONED_BIN" "${HAYABUSA_PREFIX}/hayabusa"
        fi
    fi

    chmod +x "${HAYABUSA_PREFIX}/hayabusa"
    rm -f "$DL_PATH"
    info "Hayabusa ${HAYABUSA_VERSION} installed."
fi

# ── 2. Symlink to PATH ──────────────────────────────────────────────────────
if [[ ! -L /usr/local/bin/hayabusa ]]; then
    ln -sf "${HAYABUSA_PREFIX}/hayabusa" /usr/local/bin/hayabusa
    info "Symlinked hayabusa to /usr/local/bin/"
fi

# Verify
HAYABUSA_VER=$(hayabusa --version 2>/dev/null || echo "unknown")
info "Hayabusa version: ${HAYABUSA_VER}"

# ── 3. Update Sigma rules ───────────────────────────────────────────────────
info "Updating Hayabusa Sigma rules …"
cd "$HAYABUSA_PREFIX"
hayabusa update-rules 2>&1 | tail -5 || warn "Rule update had issues — may need manual update."

RULE_COUNT=$(find "${HAYABUSA_PREFIX}/rules" -name '*.yml' 2>/dev/null | wc -l)
info "Sigma rules available: ${RULE_COUNT}"

# ── 4. Create EVTX evidence directory ───────────────────────────────────────
mkdir -p "${EVTX_DIR}"
info "EVTX drop directory: ${EVTX_DIR}"

# ── 5. Smoke test ───────────────────────────────────────────────────────────
info "Running smoke test …"
if hayabusa help > /dev/null 2>&1; then
    info "Smoke test PASSED — hayabusa binary runs."
else
    warn "Smoke test: hayabusa binary failed to run."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log "40-hayabusa completed"
info "Module 40-hayabusa complete."
info "Usage: hayabusa csv-timeline -d ${EVTX_DIR} -o results.csv"
info "       hayabusa json-timeline -d ${EVTX_DIR} -o results.json"
