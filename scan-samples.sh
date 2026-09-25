#!/usr/bin/env bash
# =============================================================================
# scan-samples.sh — Batch YARA scan against community rulesets
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    info()  { echo -e "\033[0;32m[+]\033[0m $*"; }
    warn()  { echo -e "\033[1;33m[!]\033[0m $*"; }
    error() { echo -e "\033[0;31m[✗]\033[0m $*"; exit 1; }
fi

CONF_FILE="${SCRIPT_DIR}/st0ne_buntu.conf"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

YARA_RULES_DIR="/opt/yara-rules"
HITS_DIR="${YARA_HITS_DIR:-/opt/st0ne_buntu/evidence/yara-hits}"
SCAN_TARGET="${SAMPLES_DIR:-/opt/st0ne_buntu/evidence/samples}"
CUSTOM_RULES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rules|-r) CUSTOM_RULES="$2"; shift 2 ;;
        *) SCAN_TARGET="$1"; shift ;;
    esac
done

command -v yara &>/dev/null || error "YARA not found."
[[ -e "$SCAN_TARGET" ]] || error "Scan target not found: ${SCAN_TARGET}"

mkdir -p "$HITS_DIR"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
REPORT="${HITS_DIR}/scan-${TIMESTAMP}.txt"
REPORT_JSON="${HITS_DIR}/scan-${TIMESTAMP}.json"

info "════════════════════════════════════════════════════════════"
info "  YARA Scan"
info "════════════════════════════════════════════════════════════"

run_scan() {
    local ruleset_name="$1"
    local rules_path="$2"

    if [[ ! -e "$rules_path" ]]; then
        warn "  Rules not found: ${rules_path}"
        return
    fi

    info "Scanning with ${ruleset_name} …"
    echo "=== ${ruleset_name} ===" >> "$REPORT"

    if [[ -d "$SCAN_TARGET" ]]; then
        yara -r -s -w "$rules_path" "$SCAN_TARGET" 2>/dev/null >> "$REPORT" || true
    else
        yara -s -w "$rules_path" "$SCAN_TARGET" 2>/dev/null >> "$REPORT" || true
    fi
    echo "" >> "$REPORT"
}

if [[ -n "$CUSTOM_RULES" ]]; then
    run_scan "Custom rules" "$CUSTOM_RULES"
else
    if [[ -d "${YARA_RULES_DIR}/signature-base/yara" ]]; then
        find "${YARA_RULES_DIR}/signature-base/yara" -maxdepth 1 -name '*.yar' | \
        while IFS= read -r rulefile; do
            RULE_NAME=$(basename "$rulefile" .yar)
            yara -r -w "$rulefile" "$SCAN_TARGET" 2>/dev/null | while IFS= read -r match; do
                echo "[signature-base/${RULE_NAME}] ${match}" >> "$REPORT"
            done
        done
    else
        warn "signature-base rules not found."
    fi

    FORGE_RULES=$(find "${YARA_RULES_DIR}/yara-forge" -maxdepth 2 -name '*.yar' 2>/dev/null | head -5)
    if [[ -n "$FORGE_RULES" ]]; then
        while IFS= read -r rulefile; do
            RULE_NAME=$(basename "$rulefile" .yar)
            yara -r -w "$rulefile" "$SCAN_TARGET" 2>/dev/null | while IFS= read -r match; do
                echo "[yara-forge/${RULE_NAME}] ${match}" >> "$REPORT"
            done
        done <<< "$FORGE_RULES"
    fi
fi

# Count hits uniformly based on both standard YARA and prefixed outputs
TOTAL_HITS=$(grep -cE '^(\[|[a-zA-Z0-9_]+ +/)' "$REPORT" 2>/dev/null || echo 0)

python3 -c "
import json, re, datetime
hits = []
with open('${REPORT}') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('==='):
            continue
        m = re.match(r'\[([^\]]+)\]\s+(\S+)\s+(.*)', line)
        if m:
            hits.append({
                '@timestamp': datetime.datetime.utcnow().isoformat(),
                'source_tool': 'yara',
                'ruleset': m.group(1),
                'rule_name': m.group(2),
                'matched_file': m.group(3),
                'scan_target': '${SCAN_TARGET}'
            })
        elif re.match(r'^[a-zA-Z]', line):
            parts = line.split(None, 1)
            if len(parts) == 2:
                hits.append({
                    '@timestamp': datetime.datetime.utcnow().isoformat(),
                    'source_tool': 'yara',
                    'rule_name': parts[0],
                    'matched_file': parts[1],
                    'scan_target': '${SCAN_TARGET}'
                })
with open('${REPORT_JSON}', 'w') as f:
    for h in hits:
        f.write(json.dumps(h) + '\n')
" 2>/dev/null || warn "JSON report generation had issues."

info "════════════════════════════════════════════════════════════"
info "  Hits:      ${TOTAL_HITS}"
info "════════════════════════════════════════════════════════════"