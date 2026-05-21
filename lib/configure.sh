#!/usr/bin/env bash
# =============================================================================
# lib/configure.sh — Interactive first-run configuration
# =============================================================================

generate_config() {
    local conf_file="$1"

    banner "st0ne_buntu — First-time configuration"
    echo ""

    # ── Network interface ────────────────────────────────────────────────────
    # Default to lo — this VM is primarily used for offline PCAP analysis.
    # Team members doing live capture can override with their physical interface.
    local default_iface="lo"
    local physical_iface
    physical_iface=$(ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty' 2>/dev/null || true)

    echo "  Detected physical interface: ${physical_iface:-none}"
    echo "  Default is 'lo' (offline/PCAP analysis mode)."
    echo "  Use your physical interface (${physical_iface}) for live network capture."
    read -rp "Network interface to monitor [${default_iface}]: " IFACE
    IFACE="${IFACE:-$default_iface}"

    # ── HOME_NET ─────────────────────────────────────────────────────────────
    # Default to "any" — this VM analyses PCAPs from arbitrary networks,
    # so restricting HOME_NET would cause rules to silently miss traffic.
    local default_home_net="any"

    echo "  Default HOME_NET is 'any' (matches all traffic in PCAPs)."
    echo "  For live monitoring, set to your actual subnet (e.g. 192.168.1.0/24)."
    read -rp "HOME_NET [${default_home_net}]: " HOME_NET
    HOME_NET="${HOME_NET:-$default_home_net}"

    # ── Evidence directory ───────────────────────────────────────────────────
    local default_evidence="/opt/st0ne_buntu/evidence"
    read -rp "Evidence/working directory [${default_evidence}]: " EVIDENCE_DIR
    EVIDENCE_DIR="${EVIDENCE_DIR:-$default_evidence}"

    # ── PCAP retention ───────────────────────────────────────────────────────
    read -rp "Max PCAP storage in GB [50]: " PCAP_MAX_GB
    PCAP_MAX_GB="${PCAP_MAX_GB:-50}"

    # ── ES index retention ───────────────────────────────────────────────────
    read -rp "ES index retention in days [30]: " ES_RETENTION_DAYS
    ES_RETENTION_DAYS="${ES_RETENTION_DAYS:-30}"

    # ── ES security ──────────────────────────────────────────────────────────
    read -rp "Disable ES security/TLS for lab use? [Y/n]: " ES_DISABLE_SECURITY
    ES_DISABLE_SECURITY="${ES_DISABLE_SECURITY:-Y}"

    # ── Optional components ─────────────────────────────────────────────────
    echo ""
    echo "  Arkime is a large download (~150 MB). Skip if bandwidth is limited"
    echo "  or you don't need full packet capture/session indexing."
    read -rp "Install Arkime? [Y/n]: " INSTALL_ARKIME
    INSTALL_ARKIME="${INSTALL_ARKIME:-Y}"

    # ── Write config ─────────────────────────────────────────────────────────
    cat > "$conf_file" <<EOF
# =============================================================================
# st0ne_buntu.conf — Generated $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file to change settings, then re-run modules as needed.
# =============================================================================

# ── Network ──────────────────────────────────────────────────────────────────
IFACE="${IFACE}"
HOME_NET="${HOME_NET}"
EXTERNAL_NET="any"

# ── Directories ──────────────────────────────────────────────────────────────
EVIDENCE_DIR="${EVIDENCE_DIR}"
PCAP_DIR="${EVIDENCE_DIR}/pcap"
EVTX_DIR="${EVIDENCE_DIR}/evtx"
YARA_HITS_DIR="${EVIDENCE_DIR}/yara-hits"
KAPE_DIR="${EVIDENCE_DIR}/kape-output"
SAMPLES_DIR="${EVIDENCE_DIR}/samples"

# ── Storage limits ───────────────────────────────────────────────────────────
PCAP_MAX_GB="${PCAP_MAX_GB}"
ES_RETENTION_DAYS="${ES_RETENTION_DAYS}"

# ── Elasticsearch ────────────────────────────────────────────────────────────
ES_HOST="localhost"
ES_PORT="9200"
ES_DISABLE_SECURITY="${ES_DISABLE_SECURITY}"

# ── Service ports ────────────────────────────────────────────────────────────
KIBANA_PORT="5601"
ARKIME_PORT="8005"

# ── Optional components ──────────────────────────────────────────────────
INSTALL_ARKIME="${INSTALL_ARKIME}"
EOF

    info "Configuration written to: ${conf_file}"

    # Create evidence directories
    mkdir -p "${EVIDENCE_DIR}"/{pcap,evtx,yara-hits,kape-output,samples}
    info "Evidence directories created under: ${EVIDENCE_DIR}"
}

export -f generate_config
