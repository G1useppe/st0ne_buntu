#!/usr/bin/env bash
# =============================================================================
# rehearse-live.sh — tcpreplay orchestrator for st0ne_buntu
#
# Usage:
#   sudo ./rehearse-live.sh evidence/pcap/sample.pcap
#   sudo ./rehearse-live.sh -m 10 evidence/pcap/sample.pcap          # Replay at 10 Mbps
#   sudo ./rehearse-live.sh -x 0.28 -e 1791426600 sample.pcap        # Hot-hold until epoch
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
CONF_FILE="${SCRIPT_DIR}/st0ne_buntu.conf"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

IFACE="${IFACE:-dummy0}"
REPLAY_SPEED="-M 10" # Default to 10 Mbps
START_EPOCH=""
TARGET_PCAP=""

# ── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mbps) REPLAY_SPEED="-M $2"; shift 2 ;;
        -x|--multiplier) REPLAY_SPEED="-x $2"; shift 2 ;;
        -e|--epoch) START_EPOCH="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-m mbps | -x multiplier] [-e start_epoch] <pcap_file>"
            exit 0
            ;;
        *) TARGET_PCAP="$1"; shift ;;
    esac
done

[[ -z "$TARGET_PCAP" ]] && error "You must specify a PCAP file."
[[ ! -f "$TARGET_PCAP" ]] && error "File not found: $TARGET_PCAP"
[[ "$IFACE" != "dummy0" ]] && warn "Your configured IFACE is $IFACE, but dummy0 is recommended."

# ── Teardown Trap ────────────────────────────────────────────────────────────
cleanup() {
    echo ""
    info "Tearing down rehearsal environment …"
    systemctl stop suricata arkimecapture 2>/dev/null || true
    
    # Zeek requires zeekctl, not systemd
    if [[ -x "/opt/zeek/bin/zeekctl" ]]; then
        /opt/zeek/bin/zeekctl stop
    fi
    
    rm -rf "${NORM_DIR:-}" "${TARGET_PCAP}" 2>/dev/null || true
    info "Rehearsal complete. Services stopped."
    exit 0
}
trap cleanup EXIT INT TERM

banner "st0ne_buntu Live-Fire Rehearsal"
info "Target: $TARGET_PCAP"
info "Interface: $IFACE"

# ── 1. Normalize PCAP ────────────────────────────────────────────────────────
NORM_DIR=$(mktemp -d)
NORM_PCAP="${NORM_DIR}/normalized.pcap"

echo "# Normalizing PCAP (MTU truncation & checksums)..."
info "Normalizing PCAP (MTU truncation, fixing checksums) …"
tcprewrite --mtu=1500 --mtu-trunc --fixcsum \
    --infile="$TARGET_PCAP" \
    --outfile="$NORM_PCAP" >/dev/null 2>&1

# ── 2. Ignite Services ───────────────────────────────────────────────────────
echo "# Spinning up Suricata and Zeek on ${IFACE}..."
info "Spinning up sensors on $IFACE …"

if command -v suricata &>/dev/null; then
    systemctl start suricata
fi

if [[ -x "/opt/zeek/bin/zeekctl" ]]; then
    /opt/zeek/bin/zeekctl deploy
fi

if [[ -x "/opt/arkime/bin/capture" ]]; then
    systemctl start arkimecapture
fi

echo "# Waiting 5 seconds for AF_PACKET sockets to bind..."
info "Waiting 5 seconds for AF_PACKET sockets to bind …"
sleep 5

# ── 3. Hot-Sensor Hold (Synchronized DTG Release) ────────────────────────────
if [[ -n "$START_EPOCH" ]]; then
    info "Sensors are HOT. Holding for synchronized release at epoch ${START_EPOCH} …"
    while true; do
        NOW=$(date +%s)
        REM=$(( START_EPOCH - NOW ))
        [[ $REM -le 0 ]] && break
        echo "# Sensors HOT on ${IFACE} — Firing in ${REM}s..."
        sleep 0.1
    done
fi

# ── 4. Execute Replay ────────────────────────────────────────────────────────
echo "# Injecting traffic (${REPLAY_SPEED}) into ${IFACE}..."
banner "Firing traffic … (Press Ctrl+C to abort)"
tcpreplay -i "$IFACE" $REPLAY_SPEED "$NORM_PCAP"

echo "# Traffic complete. Flushing Filebeat logs..."
info "Traffic complete. Waiting 5 seconds for Filebeat to flush logs …"
sleep 5
