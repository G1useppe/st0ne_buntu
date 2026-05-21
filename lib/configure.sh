#!/usr/bin/env bash
# =============================================================================
# lib/configure.sh — Interactive first-run configuration
# =============================================================================

generate_config() {
    local conf_file="$1"

    banner "st0ne_buntu — First-time configuration"
    echo ""

    # ── Network interface ────────────────────────────────────────────────────
    local default_iface
    default_iface=$(ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty' 2>/dev/null || true)
    [[ -z "$default_iface" ]] && default_iface=$(ip -o link show up | awk -F': ' '!/lo/{print $2; exit}')

    read -rp "Network interface to monitor [${default_iface}]: " IFACE
    IFACE="${IFACE:-$default_iface}"

    # ── HOME_NET ─────────────────────────────────────────────────────────────
    local detected_nets
    detected_nets=$(ip -4 -o addr show scope global | awk '{print $4}' | paste -sd, -)
    [[ -z "$detected_nets" ]] && detected_nets="192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"

    read -rp "HOME_NET subnets [${detected_nets}]: " HOME_NET
    HOME_NET="${HOME_NET:-$detected_nets}"

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

    # ── Write config ─────────────────────────────────────────────────────────
    cat > "$conf_file" <<EOF
# =============================================================================
# st0ne_buntu.conf — Generated $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file to change settings, then re-run modules as needed.
# =============================================================================

# ── Network ──────────────────────────────────────────────────────────────────
IFACE="${IFACE}"
HOME_NET="[${HOME_NET}]"

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
EOF

    info "Configuration written to: ${conf_file}"

    # Create evidence directories
    mkdir -p "${EVIDENCE_DIR}"/{pcap,evtx,yara-hits,kape-output,samples}
    info "Evidence directories created under: ${EVIDENCE_DIR}"
}

export -f generate_config
