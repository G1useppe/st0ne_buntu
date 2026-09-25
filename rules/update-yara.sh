#!/usr/bin/env bash
# =============================================================================
# rules/update-yara.sh — Pull latest community YARA rulesets
# =============================================================================

set -euo pipefail

YARA_RULES_DIR="/opt/yara-rules"
LOG="/var/log/st0ne_buntu_rule_update.log"

echo "[$(date)] Starting YARA rule update" >> "$LOG"

if [[ -d "${YARA_RULES_DIR}/signature-base" ]]; then
    git -C "${YARA_RULES_DIR}/signature-base" pull --quiet >> "$LOG" 2>&1
else
    git clone --quiet https://github.com/Neo23x0/signature-base.git \
        "${YARA_RULES_DIR}/signature-base" >> "$LOG" 2>&1
fi

mkdir -p "${YARA_RULES_DIR}/yara-forge"
curl -fsSL "https://github.com/YARAHQ/yara-forge/releases/latest/download/yara-forge-rules-full.zip" \
    -o "${YARA_RULES_DIR}/yara-forge/yaraforge-rules.zip" 2>> "$LOG" && \
    unzip -qo "${YARA_RULES_DIR}/yara-forge/yaraforge-rules.zip" \
    -d "${YARA_RULES_DIR}/yara-forge/" 2>> "$LOG" || true

echo "[$(date)] YARA rule update complete" >> "$LOG"