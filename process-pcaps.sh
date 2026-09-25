#!/usr/bin/env bash
# =============================================================================
# process-pcaps.sh — Run Suricata + Zeek against PCAPs, ingest into ELK + Arkime
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    info()  { echo -e "\033[0;32m[+]\033[0m $*"; }
    warn()  { echo -e "\033[1;33m[!]\033[0m $*"; }
    error() { echo -e "\033[0;31m[✗]\033[0m $*"; exit 1; }
fi

CONF_FILE="${SCRIPT_DIR}/st0ne_buntu.conf"
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
fi

PCAP_DIR="${EVIDENCE_DIR:-/opt/st0ne_buntu/evidence}/pcap"
PROCESSED_DIR="${EVIDENCE_DIR:-/opt/st0ne_buntu/evidence}/processed"
SURICATA_CONF="/etc/suricata/suricata.yaml"
SURICATA_LIVE_EVE="/var/log/suricata/eve.json"
ZEEK_BIN="/opt/zeek/bin/zeek"
ARKIME_CONF="/opt/arkime/etc/config.ini"
ARKIME_CAPTURE="/opt/arkime/bin/capture"

# ── Parse arguments ──────────────────────────────────────────────────────────
REPROCESS=false
NO_INGEST=false
TARGET_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reprocess|-r) REPROCESS=true; shift ;;
        --no-ingest|-n) NO_INGEST=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--reprocess] [--no-ingest] [specific.pcap]"
            exit 0
            ;;
        *) TARGET_FILE="$1"; shift ;;
    esac
done

# ── Preflight ────────────────────────────────────────────────────────────────
[[ -d "$PCAP_DIR" ]] || error "PCAP directory not found: ${PCAP_DIR}"

if ! command -v suricata &>/dev/null; then
    error "Suricata not found. Run install.sh --module 20 first."
fi

if [[ ! -x "$ZEEK_BIN" ]]; then
    warn "Zeek not found at ${ZEEK_BIN}. Zeek analysis will be skipped."
    ZEEK_AVAILABLE=false
else
    ZEEK_AVAILABLE=true
    export PATH="/opt/zeek/bin:$PATH"
fi

[[ -f "$SURICATA_CONF" ]] || error "Suricata config not found: ${SURICATA_CONF}"

ARKIME_AVAILABLE=false
ES_AVAILABLE=false

if [[ "$NO_INGEST" == false ]]; then
    if [[ -x "$ARKIME_CAPTURE" && -f "$ARKIME_CONF" ]]; then
        ARKIME_AVAILABLE=true
    else
        warn "Arkime not found. PCAP session import will be skipped."
    fi

    if curl -sf "http://${ES_HOST:-localhost}:${ES_PORT:-9200}/_cluster/health" > /dev/null 2>&1; then
        ES_AVAILABLE=true
    else
        warn "Elasticsearch not reachable. Filebeat ingest will not work."
    fi
fi

mkdir -p "$PROCESSED_DIR"

# ── Build file list ──────────────────────────────────────────────────────────
PCAP_FILES=()

if [[ -n "$TARGET_FILE" ]]; then
    if [[ -f "${PCAP_DIR}/${TARGET_FILE}" ]]; then
        PCAP_FILES+=("${PCAP_DIR}/${TARGET_FILE}")
    elif [[ -f "$TARGET_FILE" ]]; then
        PCAP_FILES+=("$TARGET_FILE")
    else
        error "File not found: ${TARGET_FILE}"
    fi
else
    while IFS= read -r -d '' f; do
        PCAP_FILES+=("$f")
    done < <(find "$PCAP_DIR" -maxdepth 1 -type f \( -name '*.pcap' -o -name '*.pcapng' -o -name '*.cap' \) -print0 | sort -z)
fi

if [[ ${#PCAP_FILES[@]} -eq 0 ]]; then
    warn "No PCAP files found in ${PCAP_DIR}/"
    exit 0
fi

info "Found ${#PCAP_FILES[@]} PCAP file(s) to process."

# ── Process each PCAP ────────────────────────────────────────────────────────
TOTAL=${#PCAP_FILES[@]}
CURRENT=0
FAILED=0

for pcap in "${PCAP_FILES[@]}"; do
    # Resolve relative paths before cd
    pcap=$(realpath "$pcap")
    
    CURRENT=$((CURRENT + 1))
    BASENAME=$(basename "$pcap")
    NAME="${BASENAME%.*}"
    OUTPUT_DIR="${PROCESSED_DIR}/${NAME}"
    SURI_DIR="${OUTPUT_DIR}/suricata"
    ZEEK_DIR="${OUTPUT_DIR}/zeek"

    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "[${CURRENT}/${TOTAL}] Processing: ${BASENAME}"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ -d "$OUTPUT_DIR" && "$REPROCESS" == false ]]; then
        info "Already processed. Use --reprocess to re-run. Skipping."
        continue
    fi

    rm -rf "$OUTPUT_DIR"
    mkdir -p "$SURI_DIR" "$ZEEK_DIR"

    # ── Suricata (local output) ──────────────────────────────────────────
    info "Running Suricata …"
    if suricata -r "$pcap" -c "$SURICATA_CONF" -l "$SURI_DIR" -k none 2>&1 | grep -E 'rules successfully loaded|read.*file.*packets|Alerts:'; then
        ALERT_COUNT=$(wc -l < "${SURI_DIR}/fast.log" 2>/dev/null || echo 0)
        info "Suricata complete: ${ALERT_COUNT} alerts"
    else
        warn "Suricata had issues processing ${BASENAME}"
        FAILED=$((FAILED + 1))
    fi

    if [[ "$ES_AVAILABLE" == true && "$NO_INGEST" == false ]]; then
        if [[ -f "${SURI_DIR}/eve.json" ]]; then
            info "Appending Suricata EVE to live log for Filebeat ingest …"
            cat "${SURI_DIR}/eve.json" >> "$SURICATA_LIVE_EVE"
        fi
    fi

    # ── Zeek ─────────────────────────────────────────────────────────────
    if [[ "$ZEEK_AVAILABLE" == true ]]; then
        info "Running Zeek …"
        cd "$ZEEK_DIR"
        if "${ZEEK_BIN}" -r "$pcap" LogAscii::use_json=T policy/protocols/conn/community-id-logging 2>&1 | tail -3; then
            LOG_COUNT=$(find "$ZEEK_DIR" -name '*.log' | wc -l)
            info "Zeek complete: ${LOG_COUNT} log files"
        else
            warn "Zeek had issues processing ${BASENAME}"
            FAILED=$((FAILED + 1))
        fi
        cd - > /dev/null
        
        # Ingest Zeek output to Filebeat path
        if [[ "$ES_AVAILABLE" == true && "$NO_INGEST" == false ]]; then
            info "Copying Zeek logs to /opt/zeek/logs/current for Filebeat ingest …"
            cp "${ZEEK_DIR}"/*.log "/opt/zeek/logs/current/" 2>/dev/null || true
        fi
    fi

    # ── Arkime import ────────────────────────────────────────────────────
    if [[ "$ARKIME_AVAILABLE" == true && "$NO_INGEST" == false ]]; then
        info "Importing into Arkime …"
        if "$ARKIME_CAPTURE" --copy -r "$pcap" -c "$ARKIME_CONF" 2>&1 | tail -3; then
            info "Arkime import complete → view at http://localhost:${ARKIME_PORT:-8005}"
        else
            warn "Arkime import had issues for ${BASENAME}"
        fi
    fi

    info "Output: ${OUTPUT_DIR}/"
done

if [[ "$ES_AVAILABLE" == true && "$NO_INGEST" == false ]]; then
    info "Waiting for Filebeat to ship data to Elasticsearch …"
    sleep 10
fi

info "════════════════════════════════════════════════════════════"
info "  Processing complete: ${TOTAL} PCAP(s)"
info "════════════════════════════════════════════════════════════"