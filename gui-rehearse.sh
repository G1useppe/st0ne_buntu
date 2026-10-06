#!/usr/bin/env bash
# =============================================================================
# gui-rehearse.sh — Zenity GUI wrapper for live-fire orchestrator
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

# 3. Dynamic Value Input
if [[ "$MODE" == *"Time"* ]]; then
    DURATION=$(zenity --entry \
        --title="Time Stretch" \
        --text="Enter total duration (e.g., 5h, 30m, 7200s):" \
        --entry-text="5h")
    [[ -z "$DURATION" ]] && exit 0
    SPEED_FLAG="-t ${DURATION}"
else
    # Upgraded to allow manual float input for slow-mo
    SPEED=$(zenity --entry \
        --title="Speed Multiplier" \
        --text="Enter traffic multiplier (e.g., 1 for real-time, 0.01 for slow-mo):" \
        --entry-text="0.01")
    [[ -z "$SPEED" ]] && exit 0
    SPEED_FLAG="-x ${SPEED}"
fi

# 4. Graphical Sudo Check
if ! command -v pkexec &>/dev/null; then
    zenity --error --text="pkexec not found. Cannot prompt for admin rights."
    exit 1
fi

# 5. Auto-Launch Kibana Dashboard
# This pre-builds the URL to search for Zeek connections over the last 15 minutes
KIBANA_URL="http://localhost:5601/app/discover#/?_g=(time:(from:now-15m,to:now))&_a=(query:(language:kuery,query:'event.dataset:%22zeek.connection%22'))"
if command -v xdg-open &>/dev/null; then
    xdg-open "$KIBANA_URL" &
fi

# 6. Execution & Progress Tracking
# We echo lines starting with '#' to dynamically update the Zenity progress text
pkexec bash -c "
    for i in {10..1}; do 
        echo \"# Kibana opened. Injection begins in \$i seconds... Switch to your browser!\"; 
        sleep 1; 
    done; 
    echo \"# Spinning up sensors and injecting traffic...\";
    \"${SCRIPT_DIR}/rehearse-live.sh\" ${SPEED_FLAG} \"${PCAP_FILE}\"
" | \
    zenity --progress \
    --title="Live Rehearsal: $(basename "$PCAP_FILE")" \
    --text="Authenticating..." \
    --pulsate --auto-close --auto-kill --width=500

# 7. Completion Status
if [[ $? -eq 0 ]]; then
    zenity --info --title="Rehearsal Complete" --text="Traffic injection finished smoothly." --width=300
else
    zenity --warning --title="Rehearsal Aborted" --text="Injection cancelled.\n\nRange teardown successfully engaged." --width=300
fi
