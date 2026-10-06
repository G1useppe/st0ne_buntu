#!/usr/bin/env bash
# =============================================================================
# gui-rehearse.sh — Zenity GUI wrapper with inline PCAP time-shifting
# =============================================================================

set -euo pipefail

if ! command -v zenity &>/dev/null; then
    echo "Zenity is required. Please run: sudo apt install zenity"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Graphical File Picker
PCAP_FILE=$(zenity --file-selection \
    --title="Select Evidence PCAP" \
    --file-filter="PCAP files | *.pcap *.pcapng *.cap" \
    --filename="${PWD}/evidence/pcap/")

[[ -z "$PCAP_FILE" ]] && exit 0

# 2. Replay Mode Selector
MODE=$(zenity --list \
    --title="Rehearsal Pace" \
    --text="How do you want to pace the traffic injection?" \
    --radiolist \
    --column="Select" --column="Mode" \
    FALSE "Time Stretch (e.g. 5 hours)" TRUE "Speed Multiplier (e.g. 0.01x or 2x)" \
    --width=380 --height=220)

[[ -z "$MODE" ]] && exit 0

# 3. Dynamic Value Input & Math
if [[ "$MODE" == *"Time"* ]]; then
    DURATION=$(zenity --entry --title="Time Stretch" --text="Enter total duration (e.g., 5h, 30m, 7200s):" --entry-text="5h")
    [[ -z "$DURATION" ]] && exit 0
    SPEED_FLAG="-t ${DURATION}"
    
    # Convert to seconds for math
    if [[ "$DURATION" == *h ]]; then REPLAY_DURATION=$((${DURATION%h} * 3600))
    elif [[ "$DURATION" == *m ]]; then REPLAY_DURATION=$((${DURATION%m} * 60))
    elif [[ "$DURATION" == *s ]]; then REPLAY_DURATION=${DURATION%s}
    else REPLAY_DURATION=$DURATION; fi
else
    SPEED=$(zenity --entry --title="Speed Multiplier" --text="Enter traffic multiplier (e.g., 1 for real-time, 0.01 for slow-mo):" --entry-text="0.01")
    [[ -z "$SPEED" ]] && exit 0
    SPEED_FLAG="-x ${SPEED}"
    
    # Calculate real execution time based on speed
    ORIG_SEC=$(capinfos "$PCAP_FILE" | grep "Capture duration" | awk '{print $3}' | cut -d. -f1)
    [[ -z "$ORIG_SEC" ]] && ORIG_SEC=1
    REPLAY_DURATION=$(awk "BEGIN {print int($ORIG_SEC / $SPEED)}")
fi

# 4. Dynamic Countdown Timer
COUNTDOWN=$(zenity --scale \
    --title="Preparation Timer" \
    --text="Seconds to wait before firing traffic:" \
    --value=10 --min-value=0 --max-value=60 --step=1)

[[ $? -ne 0 ]] && exit 0

# 5. Time-Shift the PCAP (editcap)
FORGED_PCAP="/tmp/$(basename "$PCAP_FILE" .pcap)-forged.pcap"
CURRENT_EPOCH=$(date +%s)
INJECT_START_EPOCH=$((CURRENT_EPOCH + COUNTDOWN))

(
    echo "10"
    echo "#
