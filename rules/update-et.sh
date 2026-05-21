#!/usr/bin/env bash
# =============================================================================
# rules/update-et.sh — Download latest emerging-all.rules and reload Suricata
# =============================================================================

set -euo pipefail

LOG="/var/log/st0ne_buntu_rule_update.log"
RULES_DIR="/var/lib/suricata/rules"

echo "[$(date)] Starting ET rule update" >> "$LOG"

SURICATA_VER=$(suricata -V 2>/dev/null | grep -oP 'version \K[\d.]+' || echo "8.0")
MAJOR_MINOR=$(echo "$SURICATA_VER" | cut -d. -f1-2)
RULES_URL="https://rules.emergingthreats.net/open/suricata-${MAJOR_MINOR}/emerging-all.rules"

if curl -fsSL "$RULES_URL" -o "${RULES_DIR}/emerging-all.rules.tmp" >> "$LOG" 2>&1; then
    mv "${RULES_DIR}/emerging-all.rules.tmp" "${RULES_DIR}/emerging-all.rules"
    chmod 644 "${RULES_DIR}/emerging-all.rules"
    echo "[$(date)] Rules downloaded successfully" >> "$LOG"

    if systemctl is-active --quiet suricata; then
        suricatasc -c reload-rules >> "$LOG" 2>&1 || \
            systemctl reload suricata >> "$LOG" 2>&1 || true
        echo "[$(date)] Rules reloaded" >> "$LOG"
    fi
else
    echo "[$(date)] ERROR: rule download failed" >> "$LOG"
    rm -f "${RULES_DIR}/emerging-all.rules.tmp"
    exit 1
fi
