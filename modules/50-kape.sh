#!/usr/bin/env bash
# =============================================================================
# 50-kape.sh — KAPE artifact parsers (Linux-side)
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 50-kape: starting …"
export DEBIAN_FRONTEND=noninteractive

UBUNTU_VER=$(lsb_release -rs)

# ── 1. Install .NET runtime ─────────────────────────────────────────────────
if cmd_exists dotnet; then
    info ".NET runtime already installed."
else
    info "Installing .NET runtime …"
    apt_install dotnet-runtime-8.0 2>/dev/null || \
        apt_install dotnet-runtime-6.0 2>/dev/null || {
            info "Adding Microsoft .NET repository for Ubuntu ${UBUNTU_VER} …"
            curl -fsSL "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VER}/packages-microsoft-prod.deb" \
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

for pkg in libpff-utils libscca-utils; do
    apt_install "$pkg" 2>/dev/null || info "${pkg} not available in repo — skipping."
done

# Check PIP flag for system packages
PIP_BREAK=""
pip3 install --help | grep -q -- '--break-system-packages' && PIP_BREAK="--break-system-packages"

if python3 -c "import Registry; import analyzemft; import pyhindsight" 2>/dev/null; then
    info "python-registry, analyzemft, pyhindsight already installed."
else
    info "Installing python-registry, analyzemft, pyhindsight …"
    pip3 install python-registry analyzemft pyhindsight $PIP_BREAK -q 2>/dev/null || \
        warn "pip3 install failed. Python forensic parsing may be limited."
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

log "50-kape completed"
info "Module 50-kape complete."