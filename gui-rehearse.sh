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

# 2. Optional: Burn Existing Data
if zenity --question --title="Data Reset" --text="Would you like to run burn-range.sh to wipe all existing SIEM logs and PCAPs before injecting?" --width=380; then
    pkexec bash -c "\"${SCRIPT_DIR}/burn-range.sh\"" | \
        zenity --progress --title="Burning Range" --text="Wiping Elasticsearch indices and disk logs..." \
        --pulsate --auto-close --auto-kill --width=400
fi

# 3. Replay Mode Selector
MODE=$(zenity --list \
    --title="Rehearsal Pace" \
    --text="How do you want to pace the traffic injection?" \
    --radiolist \
    --column="Select" --column="Mode" \
    FALSE "Time Stretch (e.g. 5 hours)" TRUE "Speed Multiplier (e.g. 0.01x or 2x)" \
    --width=380 --height=220)

[[ -z "$MODE" ]] && exit 0

# 4. Dynamic Value Input
if [[ "$MODE" == *"Time"* ]]; then
    DURATION=$(zenity --entry \
        --title="Time Stretch" \
        --text="Enter total duration (e.g., 5h, 30m, 7200s):" \
        --entry-text="5h")
    [[ -z "$DURATION" ]] && exit 0
    SPEED_FLAG="-t ${DURATION}"
else
    SPEED=$(zenity --entry \
        --title="Speed Multiplier" \
        --text="Enter traffic multiplier (e.g., 1 for real-time, 0.01 for slow-mo):" \
        --entry-text="0.01")
    [[ -z "$SPEED" ]] && exit 0
    SPEED_FLAG="-x ${SPEED}"
fi

# 5. Dynamic Countdown Timer
COUNTDOWN=$(zenity --scale \
    --title="Preparation Timer" \
    --text="Seconds to wait before firing traffic (gives you time to arrange windows):" \
    --value=10 --min-value=0 --max-value=60 --step=1)

[[ $? -ne 0 ]] && exit 0

# 6. Kibana URL Copy-Paste Dialog
KIBANA_URL="http://localhost:5601/app/discover#/?_g=(time:(from:now-15m,to:now))&_a=(query:(language:kuery,query:%27event.dataset:%22zeek.connection%22%27))"

zenity --entry \
    --title="Action Required: Open Kibana" \
    --text="Copy this URL and paste it into Firefox.\n\nOnce your browser is ready, click OK to begin the final countdown." \
    --entry-text="$KIBANA_URL" \
    --width=600

[[ $? -ne 0 ]] && exit 0

# 7. Graphical Sudo Check
if ! command -v pkexec &>/dev/null; then
    zenity --error --text="pkexec not found. Cannot prompt for admin rights."
    exit 1
fi

# 8. Execution & Progress Tracking
pkexec bash -c "
    for (( i=${COUNTDOWN}; i>0; i-- )); do 
        echo \"# Injection begins in \$i seconds...\"; 
        sleep 1; 
    done; 
    echo \"# Spinning up sensors and injecting traffic...\";
    \"${SCRIPT_DIR}/rehearse-live.sh\" ${SPEED_FLAG} \"${PCAP_FILE}\"
" | \
    zenity --progress \
    --title="Live Rehearsal: $(basename "$PCAP_FILE")" \
    --text="Authenticating..." \
    --pulsate --auto-close --auto-kill --width=500

# 9. Completion Status
if [[ $? -eq 0 ]]; then
    zenity --info --title="Rehearsal Complete" --text="Traffic injection finished smoothly." --width=300
else
    zenity --warning --title="Rehearsal Aborted" --text="Injection cancelled.\n\nRange teardown successfully engaged." --width=300
fi
