#!/usr/bin/env bash
# =============================================================================
# gui-rehearse.sh — Zenity GUI wrapper with NTP sync & Hot-Sensor DTG launch
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

# 2. Speed Multiplier (Defaulted to 0.28 for the 2-hour serial)
SPEED=$(zenity --entry \
    --title="Speed Multiplier" \
    --text="Enter traffic multiplier (e.g., 0.28 for 90m alert window, 5.2 for 10m testflight, 1 for real-time):" \
    --entry-text="0.28")

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

# 4. NTP Server Selection
NTP_SERVER=$(zenity --entry \
    --title="Time Synchronization" \
    --text="Enter NTP server IP or hostname to sync before launch:\n(Leave as pool.ntp.org or enter your local gateway IP)" \
    --entry-text="pool.ntp.org")

[[ $? -ne 0 ]] && exit 0

# 5. Strict DTG Target Input
DEFAULT_DTG="$(date +'%Y-%m-%d') 13:30:00"
RAW_DTG=$(zenity --entry \
    --title="Strict Launch DTG" \
    --text="Enter exact launch Date-Time Group:\n• Full format: YYYY-MM-DD HH:MM:SS\n• Today shorthand: 1330 or 13:30" \
    --entry-text="$DEFAULT_DTG")

[[ -z "$RAW_DTG" ]] && exit 0

# Allow 4-digit military time shorthand (e.g., "1330" -> "YYYY-MM-DD 13:30:00")
if [[ "$RAW_DTG" =~ ^[0-9]{4}$ ]]; then
    TARGET_DTG="$(date +'%Y-%m-%d') ${RAW_DTG:0:2}:${RAW_DTG:2:2}:00"
else
    TARGET_DTG="$RAW_DTG"
fi

if ! INJECT_START_EPOCH=$(date -d "$TARGET_DTG" +%s 2>/dev/null); then
    zenity --error --title="Invalid DTG" --text="Could not parse DTG: ${TARGET_DTG}\nPlease use YYYY-MM-DD HH:MM:SS or HHMM."
    exit 1
fi

if [[ "$INJECT_START_EPOCH" -le $(date +%s) ]]; then
    zenity --error --title="DTG in the Past" --text="The specified DTG (${TARGET_DTG}) has already passed!"
    exit 1
fi

# 6. Time-Shift the PCAP (editcap) to match the exact DTG
FORGED_PCAP="/tmp/$(basename "$PCAP_FILE" .pcap)-forged.pcap"

(
    echo "10"
    echo "# Calculating timestamp offsets for ${TARGET_DTG}..."
    PCAP_START=$(tshark -r "$PCAP_FILE" -c 1 -T fields -e frame.time_epoch | cut -d. -f1)
    OFFSET=$((INJECT_START_EPOCH - PCAP_START))
    
    echo "40"
    echo "# Rewriting PCAP timestamps to match DTG..."
    editcap -t $OFFSET "$PCAP_FILE" "$FORGED_PCAP"
    
    echo "100"
) | zenity --progress --title="Forging Evidence" --text="Preparing time-shifted PCAP..." --auto-close --auto-kill --width=400

[[ $? -ne 0 ]] && exit 0

# 7. Calculate Kibana URL Time Bounds (+5 minute buffer) & 60s Auto-Refresh
INJECT_END_EPOCH=$((INJECT_START_EPOCH + REPLAY_DURATION + 300))
KIBANA_START=$(date -u -d "@$INJECT_START_EPOCH" +"%Y-%m-%dT%H:%M:%S.000Z")
KIBANA_END=$(date -u -d "@$INJECT_END_EPOCH" +"%Y-%m-%dT%H:%M:%S.000Z")

KIBANA_GLOBAL="_g=(refreshInterval:(pause:!f,value:60000),time:(from:%27${KIBANA_START}%27,to:%27${KIBANA_END}%27))"

KIBANA_ZEEK_URL="http://localhost:5601/app/discover#/?${KIBANA_GLOBAL}&_a=(query:(language:kuery,query:%27event.dataset:%22zeek.connection%22%27))"
KIBANA_SURI_URL="http://localhost:5601/app/discover#/?${KIBANA_GLOBAL}&_a=(query:(language:kuery,query:%27event.dataset:%22suricata.eve%22%20and%20suricata.eve.event_type:%22alert%22%27))"

# 8a. Kibana URL Copy-Paste Dialog (Tab 1: Zeek Connection Logs)
zenity --entry \
    --title="Kibana Link 1 of 2: Zeek Connection Logs" \
    --text="Copy this URL into your FIRST Firefox tab (Zeek Conn Logs).\n\n• Locked to ${TARGET_DTG} window\n• Pre-configured with 60s auto-refresh\n\nClick OK for the Suricata Alerts link." \
    --entry-text="$KIBANA_ZEEK_URL" \
    --width=650

[[ $? -ne 0 ]] && exit 0

# 8b. Kibana URL Copy-Paste Dialog (Tab 2: Suricata Alerts)
zenity --entry \
    --title="Kibana Link 2 of 2: Suricata Alerts" \
    --text="Copy this URL into your SECOND Firefox tab (Suricata IDS Alerts).\n\n• Locked to ${TARGET_DTG} window\n• Pre-configured with 60s auto-refresh\n\nOnce both browser tabs are ready, click OK to authenticate, sync NTP, and arm the launcher." \
    --entry-text="$KIBANA_SURI_URL" \
    --width=650

[[ $? -ne 0 ]] && exit 0

# 9. Graphical Sudo Check
if ! command -v pkexec &>/dev/null; then
    zenity --error --text="pkexec not found. Cannot prompt for admin rights."
    exit 1
fi

# 10. NTP Sync, T-60s Pre-Flight Ignition, and Hot-Sensor Execution
PREFLIGHT_EPOCH=$((INJECT_START_EPOCH - 60))

pkexec bash -c "
    if [[ -n \"${NTP_SERVER}\" ]]; then
        echo \"# Syncing system clock with ${NTP_SERVER}...\"
        if command -v ntpdate &>/dev/null; then
            ntpdate -u \"${NTP_SERVER}\" >/dev/null 2>&1 || true
        else
            mkdir -p /etc/systemd/timesyncd.conf.d
            printf \"[Time]\nNTP=%s\n\" \"${NTP_SERVER}\" > /etc/systemd/timesyncd.conf.d/rehearse-ntp.conf
            timedatectl set-ntp true >/dev/null 2>&1 || true
            systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
            sleep 2
        fi
    fi

    # Stage 1: Hold until T-minus 60s before spinning up sensors
    while true; do
        NOW=\$(date +%s)
        REM=\$(( ${PREFLIGHT_EPOCH} - NOW ))
        [[ \$REM -le 0 ]] && break
        MINS=\$(( REM / 60 ))
        SECS=\$(( REM % 60 ))
        printf \"# Armed for ${TARGET_DTG} — Sensor pre-flight in %02dm %02ds...\n\" \"\$MINS\" \"\$SECS\"
        sleep 0.5
    done

    echo \"# T-60s: Normalizing PCAP and igniting sensors...\"
    \"${SCRIPT_DIR}/rehearse-live.sh\" -e ${INJECT_START_EPOCH} ${SPEED_FLAG} \"${FORGED_PCAP}\"
" | \
    zenity --progress \
    --title="Live Rehearsal: $(basename "$PCAP_FILE")" \
    --text="Authenticating..." \
    --pulsate --auto-close --auto-kill --width=500

# 11. Completion Status
if [[ $? -eq 0 ]]; then
    zenity --info --title="Rehearsal Complete" --text="Traffic injection finished smoothly." --width=300
else
    zenity --warning --title="Rehearsal Aborted" --text="Injection cancelled." --width=300
fi
