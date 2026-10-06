#!/usr/bin/env bash
#
# =============================================================================
# gui-rehearse.sh — Zenity GUI wrapper for live-fire orchestrator
# =============================================================================

set -euo pipefail

# Ensure Zenity is installed for the GUI components
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

# Exit silently if the user clicks Cancel
[[ -z "$PCAP_FILE" ]] && exit 0

# 2. Replay Speed Selector
SPEED=$(zenity --list \
    --title="Rehearsal Configuration" \
    --text="Select traffic injection speed:" \
    --radiolist \
    --column="Select" --column="Multiplier" \
    TRUE "1" FALSE "2" FALSE "5" FALSE "10" \
    --width=350 --height=250)

[[ -z "$SPEED" ]] && exit 0

# 3. Graphical Sudo Check (PolicyKit)
if ! command -v pkexec &>/dev/null; then
    zenity --error --text="pkexec not found. Cannot prompt for admin rights."
    exit 1
fi

# 4. Execution & Progress Tracking
pkexec bash -c "\"${SCRIPT_DIR}/rehearse-live.sh\" -x ${SPEED} \"${PCAP_FILE}\"" | \
    zenity --progress \
    --title="Live Rehearsal: $(basename "$PCAP_FILE")" \
    --text="Spinning up sensors and injecting traffic...\n\nClick Cancel to instantly abort and tear down the range." \
    --pulsate --auto-close --auto-kill --width=500

# 5. Completion Status
if [[ $? -eq 0 ]]; then
    zenity --info --title="Rehearsal Complete" --text="Traffic injection finished smoothly.\n\nView results at http://localhost:5601" --width=300
else
    zenity --warning --title="Rehearsal Aborted" --text="Injection cancelled.\n\nRange teardown successfully engaged." --width=300
fi