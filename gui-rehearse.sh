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

# 2. Speed Multiplier (Time Stretch removed)
SPEED=$(zenity --entry \
    --title="Speed Multiplier" \
    --text="Enter traffic multiplier (e.g., 1 for real-time, 0.01 for slow-mo, 5 for fast):" \
    --entry-text="1")

[[ -z "$SPEED" ]] && exit 0
SPEED_FLAG="-x ${SPEED}"

# Calculate real execution time based on speed
ORIG_SEC=$(capinfos "$PCAP_FILE" | grep "Capture duration" | awk '{print $3}' | cut -d. -f1)
[[ -z "$ORIG_SEC" ]] && ORIG_SEC=1
REPLAY_DURATION=$(awk "BEGIN {print int($ORIG_SEC / $SPEED)}")

# 3. Optional Kibana Data View Creation
if zenity --question --title="Kibana Setup" --text="Would you like to automatically create the 'filebeat-*' Data View in Kibana?\n\n(Select 'Yes' if you just rebuilt the SIEM from scratch)"; then
    curl -s -X POST "http://localhost:5601/api/data_views/data_view" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d '{
              "data_view": {
                "title": "filebeat-*",
                "name": "Filebeat Logs",
                "timeFieldName": "@timestamp"
              }
            }' > /dev/null 2>&1
    zenity --info --title="Success" --text="Data View created! It will be waiting for you in Kibana." --timeout=3
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
    echo "# Calculating timestamp offsets..."
    PCAP_START=$(tshark -r "$PCAP_FILE" -c 1 -T fields -e frame.time_epoch | cut -d. -f1)
    OFFSET=$((INJECT_START_EPOCH - PCAP_START))
    
    echo "40"
    echo "# Rewriting timestamps to current time..."
    editcap -t $OFFSET "$PCAP_FILE" "$FORGED_PCAP"
    
    echo "100"
) | zenity --progress --title="Forging Evidence" --text="Preparing time-shifted PCAP..." --auto-close --auto-kill --width=400

[[ $? -ne 0 ]] && exit 0

# 6. Calculate Kibana URL Time Bounds (+5 minute buffer)
INJECT_END_EPOCH=$((INJECT_START_EPOCH + REPLAY_DURATION + 300))
KIBANA_START=$(date -u -d "@$INJECT_START_EPOCH" +"%Y-%m-%dT%H:%M:%S.000Z")
KIBANA_END=$(date -u -d "@$INJECT_END_EPOCH" +"%Y-%m-%dT%H:%M:%S.000Z")

# Discover URL pre-filtered for Zeek connection logs within the exact time window
KIBANA_URL="http://localhost:5601/app/discover#/?_g=(time:(from:%27${KIBANA_START}%27,to:%27${KIBANA_END}%27))&_a=(query:(language:kuery,query:%27event.dataset:%22zeek.connection%22%27))"

# 7. Kibana URL Copy-Paste Dialog
zenity --entry \
    --title="Action Required: Open Kibana Discover" \
    --text="Copy this URL and paste it into Firefox.\n\nNote: This link takes you to the Discover tab, pre-filtered for Zeek conn logs, and locked to the exact ${COUNTDOWN}s countdown until the PCAP finishes replaying (+5 min buffer).\n\nOnce your browser is ready, click OK to begin." \
    --entry-text="$KIBANA_URL" \
    --width=600

[[ $? -ne 0 ]] && exit 0

# 8. Graphical Sudo Check
if ! command -v pkexec &>/dev/null; then
    zenity --error --text="pkexec not found. Cannot prompt for admin rights."
    exit 1
fi

# 9. Execution & Progress Tracking
pkexec bash -c "
    for (( i=${COUNTDOWN}; i>0; i-- )); do 
        echo \"# Injection begins in \$i seconds...\"; 
        sleep 1; 
    done; 
    echo \"# Spinning up sensors and injecting traffic...\";
    \"${SCRIPT_DIR}/rehearse-live.sh\" ${SPEED_FLAG} \"${FORGED_PCAP}\"
" | \
    zenity --progress \
    --title="Live Rehearsal: $(basename "$PCAP_FILE")" \
    --text="Authenticating..." \
    --pulsate --auto-close --auto-kill --width=500

# 10. Completion Status
if [[ $? -eq 0 ]]; then
    zenity --info --title="Rehearsal Complete" --text="Traffic injection finished smoothly." --width=300
else
    zenity --warning --title="Rehearsal Aborted" --text="Injection cancelled." --width=300
fi
