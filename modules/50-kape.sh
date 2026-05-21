#!/usr/bin/env bash
# =============================================================================
# 50-kape.sh — KAPE artifact parsers (Linux-side)
#
# Purpose:
#   Set up the Linux-side tooling for working with KAPE triage output.
#   KAPE itself is a Windows tool (requires manual download from Kroll).
#   This module installs parsers and utilities for analysing KAPE output
#   on the Ubuntu workstation.
#
# What this module does:
#   - Install .NET runtime (for EZ Tools that have Linux builds)
#   - Install useful parsing tools:
#       * python-registry — Windows registry hive parsing
#       * libesedb-utils — ESE database parsing (e.g. SRUM, BITS)
#       * libpff-utils — Outlook PST/OST parsing
#       * libevtx-utils — Windows EVTX parsing (native, no .NET)
#       * libscca-utils — Windows prefetch parsing
#       * csvkit — CSV analysis from the command line
#   - Create KAPE output directory
#   - Install regripper for registry analysis
#
# NOTE: KAPE itself cannot be auto-downloaded (requires Kroll account).
# Download manually from https://www.kroll.com/en/services/cyber-risk/
#   incident-response-litigation-support/kroll-artifact-parser-extractor-kape
#
# Depends on: 00-base
# Config used: KAPE_DIR
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 50-kape: starting …"
export DEBIAN_FRONTEND=noninteractive

# ── 1. Install .NET runtime ─────────────────────────────────────────────────
if cmd_exists dotnet; then
    info ".NET runtime already installed."
else
    info "Installing .NET runtime …"
    apt_install dotnet-runtime-8.0 2>/dev/null || \
        apt_install dotnet-runtime-6.0 2>/dev/null || {
            # Fallback: add Microsoft repo
            info "Adding Microsoft .NET repository …"
            curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb \
                -o /tmp/packages-microsoft-prod.deb
            dpkg -i /tmp/packages-microsoft-prod.deb 2>/dev/null || true
            rm -f /tmp/packages-microsoft-prod.deb
            apt-get update -qq
            apt_install dotnet-runtime-8.0 || warn ".NET runtime install failed."
        }
fi

if cmd_exists dotnet; then
    DOTNET_VER=$(dotnet --info 2>/dev/null | grep -m1 'Version' | awk '{print $2}' || echo "installed")
    info ".NET runtime: ${DOTNET_VER}"
else
    warn ".NET runtime not available. Some EZ Tools may not work."
fi

# ── 2. Install forensic parsing libraries ────────────────────────────────────
info "Installing forensic parsing tools …"
apt_install libesedb-utils libevtx-utils csvkit

# These may not be in all Ubuntu repos — install individually
for pkg in libpff-utils libscca-utils; do
    apt_install "$pkg" 2>/dev/null || info "${pkg} not available in repo — skipping."
done

# python-registry for Windows registry hive parsing
if python3 -c "import Registry" 2>/dev/null; then
    info "python-registry already installed."
else
    info "Installing python-registry …"
    pip3 install python-registry --break-system-packages -q 2>/dev/null || \
        warn "python-registry install failed."
fi

# ── 3. Install RegRipper ────────────────────────────────────────────────────
REGRIPPER_DIR="/opt/regripper"
if [[ -d "$REGRIPPER_DIR" ]]; then
    info "RegRipper already installed."
else
    info "Installing RegRipper …"
    apt_install libparse-win32registry-perl 2>/dev/null || true
    git clone --quiet --depth 1 https://github.com/keydet89/RegRipper3.0.git \
        "$REGRIPPER_DIR" 2>&1 || warn "RegRipper clone failed."

    if [[ -f "${REGRIPPER_DIR}/rip.pl" ]]; then
        chmod +x "${REGRIPPER_DIR}/rip.pl"
        ln -sf "${REGRIPPER_DIR}/rip.pl" /usr/local/bin/rip.pl 2>/dev/null || true
        info "RegRipper installed at ${REGRIPPER_DIR}"
    fi
fi

# ── 4. Create KAPE output directory ─────────────────────────────────────────
mkdir -p "${KAPE_DIR}"
info "KAPE output directory: ${KAPE_DIR}"

# ── 5. Smoke test ───────────────────────────────────────────────────────────
info "Running smoke tests …"
PASS=0; TOTAL=0

for tool in esedbexport pffexport evtxexport csvstat; do
    TOTAL=$((TOTAL + 1))
    if cmd_exists "$tool"; then
        PASS=$((PASS + 1))
    else
        warn "  ${tool} not found."
    fi
done

info "Smoke test: ${PASS}/${TOTAL} parsing tools available."

# ── Done ─────────────────────────────────────────────────────────────────────
log "50-kape completed"
info "Module 50-kape complete."
info ""
info "KAPE output analysis workflow:"
info "  1. Run KAPE on Windows target → collect to USB/share"
info "  2. Copy KAPE output to ${KAPE_DIR}/"
info "  3. Parse artifacts:"
info "     Registry: rip.pl -r ${KAPE_DIR}/Registry/SYSTEM -p system"
info "     EVTX:     evtxexport ${KAPE_DIR}/EventLogs/Security.evtx"
info "     Prefetch: hayabusa csv-timeline -d ${KAPE_DIR}/EventLogs/"
info "     ESE DB:   esedbexport ${KAPE_DIR}/SRUDB.dat"
