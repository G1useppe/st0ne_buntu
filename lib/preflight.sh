#!/usr/bin/env bash
# =============================================================================
# lib/preflight.sh — Pre-installation validation
# =============================================================================

run_preflight() {
    local mode="${1:-install}"
    local failed=0

    banner "Running preflight checks …"

    # ── OS check ─────────────────────────────────────────────────────────────
    if grep -qiE 'ubuntu' /etc/os-release 2>/dev/null; then
        local version
        version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        info "OS: Ubuntu ${version}"
        if [[ "$version" != "22.04" && "$version" != "24.04" ]]; then
            warn "Tested on 22.04 and 24.04. Your version (${version}) may work but is untested."
        fi
    else
        error "This project requires Ubuntu. Detected a different OS."
    fi

    # ── Architecture ─────────────────────────────────────────────────────────
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        warn "Architecture: ${arch}. Some tools (Hayabusa, Arkime) may not have builds."
    else
        info "Architecture: ${arch}"
    fi

    # ── RAM check ────────────────────────────────────────────────────────────
    local ram_mb
    ram_mb=$(total_ram_mb)
    info "RAM: ${ram_mb} MB"
    if [[ $ram_mb -lt 8192 ]]; then
        warn "Less than 8 GB RAM detected. The full stack may struggle."
        warn "Consider running fewer modules or allocating more RAM."
        ((failed++))
    elif [[ $ram_mb -lt 16384 ]]; then
        warn "8-16 GB RAM. Workable, but ES heap and Arkime will be constrained."
    else
        info "RAM is sufficient for the full stack."
    fi

    # ── Disk check ───────────────────────────────────────────────────────────
    local disk_gb
    disk_gb=$(df -BG / | awk 'NR==2 {print int($4)}')
    info "Free disk: ${disk_gb} GB"
    if [[ $disk_gb -lt 40 ]]; then
        warn "Less than 40 GB free. PCAP storage and ES indices will fill fast."
        ((failed++))
    fi

    # ── Internet connectivity ────────────────────────────────────────────────
    if curl -sf --max-time 5 https://packages.elastic.co > /dev/null 2>&1; then
        info "Internet: reachable (packages.elastic.co)"
    else
        warn "Cannot reach packages.elastic.co. Install will fail without internet."
        ((failed++))
    fi

    # ── Network interface ────────────────────────────────────────────────────
    local iface
    iface=$(ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty' 2>/dev/null || true)
    if [[ -n "$iface" ]]; then
        info "Default interface: ${iface}"
    else
        warn "Could not detect default network interface."
        ((failed++))
    fi

    # ── Summary ──────────────────────────────────────────────────────────────
    if [[ $failed -gt 0 ]]; then
        warn "${failed} warning(s) found. Review above before proceeding."
    else
        info "All preflight checks passed."
    fi
}

export -f run_preflight
