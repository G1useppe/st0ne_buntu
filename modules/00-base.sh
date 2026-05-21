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
#   - Set st0ne_buntu wallpaper for all users (assets/wallpaper.png)
#
# Idempotent: yes — safe to re-run
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

export DEBIAN_FRONTEND=noninteractive

# ── 1. System update ─────────────────────────────────────────────────────────
info "Updating package index …"
apt-get update -qq
info "Upgrading installed packages …"
apt-get upgrade -y -qq

# ── 2. Common dependencies ───────────────────────────────────────────────────
info "Installing common dependencies …"
apt_install \
    curl \
    wget \
    jq \
    git \
    build-essential \
    net-tools \
    gnupg \
    apt-transport-https \
    software-properties-common \
    python3-pip \
    python3-venv \
    unzip \
    ca-certificates \
    lsb-release \
    ethtool \
    tcpdump \
    geany

# ── 3. Timezone → UTC ────────────────────────────────────────────────────────
# UTC keeps all timestamps consistent across evidence sources
CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
if [[ "$CURRENT_TZ" != "UTC" ]]; then
    info "Setting timezone to UTC (was: ${CURRENT_TZ}) …"
    timedatectl set-timezone UTC
else
    info "Timezone already UTC."
fi

# ── 4. Directory structure ───────────────────────────────────────────────────
info "Creating standard directory layout …"
DIRS=(
    "${EVIDENCE_DIR}"
    "${PCAP_DIR}"
    "${EVTX_DIR}"
    "${YARA_HITS_DIR}"
    "${KAPE_DIR}"
    "${SAMPLES_DIR}"
    "/opt/st0ne_buntu"
    "/var/log/st0ne_buntu"
)
for d in "${DIRS[@]}"; do
    if [[ ! -d "$d" ]]; then
        mkdir -p "$d"
        info "  Created: ${d}"
    fi
done

# ── 5. Sysctl tuning for network monitoring ──────────────────────────────────
SYSCTL_CONF="/etc/sysctl.d/90-st0ne_buntu.conf"
if [[ ! -f "$SYSCTL_CONF" ]]; then
    info "Applying sysctl tuning for network capture …"
    cat > "$SYSCTL_CONF" <<'SYSCTL'
# st0ne_buntu — network monitoring tuning

# Increase max receive buffer size (helps Suricata/Zeek/Arkime under load)
net.core.rmem_max = 33554432
net.core.rmem_default = 33554432

# Increase backlog for high-throughput capture
net.core.netdev_max_backlog = 10000

# Conntrack table — larger table reduces dropped connections under monitoring
net.netfilter.nf_conntrack_max = 1048576

# Disable reverse path filtering (can interfere with span/tap traffic)
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# VM memory map limit (Elasticsearch needs this)
vm.max_map_count = 262144

# Swappiness — keep ES data in RAM
vm.swappiness = 1
SYSCTL

    # Load nf_conntrack before applying (sysctl will fail if module not loaded)
    modprobe nf_conntrack 2>/dev/null || true

    sysctl --system -q
    info "Sysctl tuning applied."
else
    info "Sysctl tuning already in place."
fi

# ── 6. File descriptor and process limits ────────────────────────────────────
LIMITS_CONF="/etc/security/limits.d/90-st0ne_buntu.conf"
if [[ ! -f "$LIMITS_CONF" ]]; then
    info "Setting file descriptor and process limits …"
    cat > "$LIMITS_CONF" <<'LIMITS'
# st0ne_buntu — raised limits for ES, Suricata, Arkime
*               soft    nofile          65536
*               hard    nofile          65536
root            soft    nofile          65536
root            hard    nofile          65536
elasticsearch   soft    nofile          65536
elasticsearch   hard    nofile          65536
elasticsearch   soft    memlock         unlimited
elasticsearch   hard    memlock         unlimited
LIMITS
    info "Limits configured."
else
    info "Limits already configured."
fi

# ── 7. Ensure nf_conntrack loads at boot ─────────────────────────────────────
MODULES_CONF="/etc/modules-load.d/st0ne_buntu.conf"
if [[ ! -f "$MODULES_CONF" ]]; then
    echo "nf_conntrack" > "$MODULES_CONF"
    info "nf_conntrack set to load at boot."
fi

# ── 8. Wallpaper ─────────────────────────────────────────────────────────────
WALLPAPER_SRC="${REPO_DIR}/assets/wallpaper.png"
WALLPAPER_DEST="/opt/st0ne_buntu/wallpaper.png"

if [[ -f "$WALLPAPER_SRC" ]]; then
    cp "$WALLPAPER_SRC" "$WALLPAPER_DEST"
    info "Wallpaper copied to ${WALLPAPER_DEST}"

    # Apply for every human user (UID >= 1000) with a home directory
    while IFS=: read -r username _ uid _ _ homedir _; do
        [[ $uid -ge 1000 && -d "$homedir" ]] || continue

        # GNOME (Ubuntu 22.04 default desktop)
        if cmd_exists gsettings; then
            su - "$username" -c "
                gsettings set org.gnome.desktop.background picture-uri 'file://${WALLPAPER_DEST}' 2>/dev/null
                gsettings set org.gnome.desktop.background picture-uri-dark 'file://${WALLPAPER_DEST}' 2>/dev/null
                gsettings set org.gnome.desktop.background picture-options 'zoom' 2>/dev/null
            " 2>/dev/null || true
            info "  Wallpaper set for user: ${username}"
        fi
    done < /etc/passwd
else
    warn "No wallpaper found at ${WALLPAPER_SRC} — skipping."
    warn "Place your wallpaper at assets/wallpaper.png in the repo."
fi

# ── 9. Log setup ─────────────────────────────────────────────────────────────
touch "$LOG_FILE"
log "00-base completed"

info "Module 00-base complete."
