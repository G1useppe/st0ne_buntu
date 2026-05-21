#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared functions for all st0ne_buntu modules
# =============================================================================

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
banner(){ echo -e "${CYAN}${BOLD}$*${NC}"; }

# ── Logging ──────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/st0ne_buntu_install.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ── Idempotent helpers ───────────────────────────────────────────────────────

# Check if a systemd service exists and is active
service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# Check if a package is installed
pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

# Check if a command exists
cmd_exists() {
    command -v "$1" &>/dev/null
}

# Install packages only if not already present
apt_install() {
    local to_install=()
    for pkg in "$@"; do
        if ! pkg_installed "$pkg"; then
            to_install+=("$pkg")
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        info "Installing: ${to_install[*]}"
        apt-get install -y -qq "${to_install[@]}"
    fi
}

# Download a file only if it doesn't exist or --force is set
download_if_missing() {
    local url="$1"
    local dest="$2"
    if [[ ! -f "$dest" ]]; then
        info "Downloading: $(basename "$dest")"
        curl -fsSL "$url" -o "$dest"
    fi
}

# ── Version pinning ─────────────────────────────────────────────────────────

# Read a tool version from the versions file
get_version() {
    local tool="$1"
    local versions_file="${REPO_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}/versions.conf"
    if [[ -f "$versions_file" ]]; then
        grep "^${tool}=" "$versions_file" | cut -d= -f2 | tr -d ' "'
    fi
}

# ── Resource helpers ─────────────────────────────────────────────────────────

# Total system RAM in MB
total_ram_mb() {
    awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo
}

# Recommended ES heap size (half of allocated, capped at 50% system RAM, max 31g)
recommended_es_heap() {
    local total_mb
    total_mb=$(total_ram_mb)
    local heap_mb=$((total_mb / 4))  # 25% of total for ES
    [[ $heap_mb -lt 1024 ]] && heap_mb=1024
    [[ $heap_mb -gt 31744 ]] && heap_mb=31744
    echo "${heap_mb}m"
}

# ── Backup helper ────────────────────────────────────────────────────────────
backup_file() {
    local file="$1"
    if [[ -f "$file" && ! -f "${file}.st0ne_buntu.orig" ]]; then
        cp "$file" "${file}.st0ne_buntu.orig"
        info "Backed up: ${file}"
    fi
}

export -f info warn error banner log service_is_active pkg_installed cmd_exists
export -f apt_install download_if_missing get_version total_ram_mb
export -f recommended_es_heap backup_file
export RED GREEN YELLOW CYAN BOLD NC LOG_FILE
