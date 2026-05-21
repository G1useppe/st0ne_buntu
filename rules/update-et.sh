#!/usr/bin/env bash
# =============================================================================
# rules/update-et.sh — Update Suricata Emerging Threats Open ruleset
#
# Can be run manually or via daily cron (installed by 20-suricata module).
# =============================================================================

set -euo pipefail

LOG="/var/log/st0ne_buntu_rule_update.log"

echo "[$(date)] Starting ET Open rule update" >> "$LOG"

if /usr/bin/suricata-update -q >> "$LOG" 2>&1; then
    echo "[$(date)] Rules updated successfully" >> "$LOG"
    # Hot-reload if Suricata is running
    if systemctl is-active --quiet suricata; then
        /usr/bin/suricatasc -c reload-rules >> "$LOG" 2>&1 || \
            systemctl reload suricata >> "$LOG" 2>&1 || true
        echo "[$(date)] Rules reloaded" >> "$LOG"
    fi
else
    echo "[$(date)] ERROR: suricata-update failed" >> "$LOG"
    exit 1
fi
