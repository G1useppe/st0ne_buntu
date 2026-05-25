#!/usr/bin/env bash
# =============================================================================
# scan-samples.sh — Batch YARA scan against community rulesets
#
# Usage:
#   sudo ./scan-samples.sh                           # scan evidence/samples/
#   sudo ./scan-samples.sh /path/to/files            # scan a specific directory
#   sudo ./scan-samples.sh /path/to/file.exe         # scan a single file
#   sudo ./scan-samples.sh --rules /custom/rules.yar # use custom rules
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

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rules|-r) CUSTOM_RULES="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [target] [--rules custom.yar]"
            echo ""
            echo "  target          File or directory to scan (default: evidence/samples/)"
            echo "  --rules FILE    Use a custom YARA rules file instead of community sets"
            exit 0
            ;;
        *) SCAN_TARGET="$1"; shift ;;
    esac
done

# ── Preflight ────────────────────────────────────────────────────────────────
command -v yara &>/dev/null || error "YARA not found. Run install.sh --module 45 first."
[[ -e "$SCAN_TARGET" ]] || error "Scan target not found: ${SCAN_TARGET}"

mkdir -p "$HITS_DIR"

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
REPORT="${HITS_DIR}/scan-${TIMESTAMP}.txt"
REPORT_JSON="${HITS_DIR}/scan-${TIMESTAMP}.json"

info "════════════════════════════════════════════════════════════"
info "  YARA Scan"
info "  Target: ${SCAN_TARGET}"
info "  Report: ${REPORT}"
info "════════════════════════════════════════════════════════════"

TOTAL_HITS=0

# ── Scan function ────────────────────────────────────────────────────────────
run_scan() {
    local ruleset_name="$1"
    local rules_path="$2"
    local hits=0

    if [[ ! -e "$rules_path" ]]; then
        warn "  Rules not found: ${rules_path}"
        return
    fi

    info "Scanning with ${ruleset_name} …"
    echo "=== ${ruleset_name} ===" >> "$REPORT"

    # Run YARA, capture matches
    if [[ -d "$SCAN_TARGET" ]]; then
        yara -r -s -w "$rules_path" "$SCAN_TARGET" 2>/dev/null >> "$REPORT" || true
    else
        yara -s -w "$rules_path" "$SCAN_TARGET" 2>/dev/null >> "$REPORT" || true
    fi

    # Count hits from this ruleset
    hits=$(grep -c "^[a-zA-Z]" "$REPORT" 2>/dev/null || echo 0)
    echo "" >> "$REPORT"

    return 0
}

# ── Run scans ────────────────────────────────────────────────────────────────
if [[ -n "$CUSTOM_RULES" ]]; then
    run_scan "Custom rules" "$CUSTOM_RULES"
else
    # signature-base (Florian Roth)
    if [[ -d "${YARA_RULES_DIR}/signature-base/yara" ]]; then
        # Scan with individual rule files to avoid errors from includes
        find "${YARA_RULES_DIR}/signature-base/yara" -maxdepth 1 -name '*.yar' | \
        while IFS= read -r rulefile; do
            RULE_NAME=$(basename "$rulefile" .yar)
            yara -r -w "$rulefile" "$SCAN_TARGET" 2>/dev/null | while IFS= read -r match; do
                echo "[signature-base/${RULE_NAME}] ${match}" >> "$REPORT"
                TOTAL_HITS=$((TOTAL_HITS + 1))
            done
        done
    else
        warn "signature-base rules not found."
    fi

    # YARA-Forge
    FORGE_RULES=$(find "${YARA_RULES_DIR}/yara-forge" -maxdepth 2 -name '*.yar' 2>/dev/null | head -5)
    if [[ -n "$FORGE_RULES" ]]; then
        while IFS= read -r rulefile; do
            RULE_NAME=$(basename "$rulefile" .yar)
            yara -r -w "$rulefile" "$SCAN_TARGET" 2>/dev/null | while IFS= read -r match; do
                echo "[yara-forge/${RULE_NAME}] ${match}" >> "$REPORT"
            done
        done <<< "$FORGE_RULES"
    else
        warn "YARA-Forge rules not found."
    fi
fi

# ── Count results ────────────────────────────────────────────────────────────
TOTAL_HITS=$(grep -cE '^\[' "$REPORT" 2>/dev/null || echo 0)

# ── Generate JSON report ────────────────────────────────────────────────────
python3 -c "
import json, re, datetime

hits = []
with open('${REPORT}') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('==='):
            continue
        # Parse: [ruleset/rule] RULE_NAME file_path
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

print(f'{len(hits)} hits written to JSON')
" 2>/dev/null || warn "JSON report generation had issues."

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "════════════════════════════════════════════════════════════"
info "  Scan complete"
info "  Target:    ${SCAN_TARGET}"
info "  Hits:      ${TOTAL_HITS}"
info "  Report:    ${REPORT}"
info "  JSON:      ${REPORT_JSON}"
info ""
if [[ $TOTAL_HITS -gt 0 ]]; then
    info "  Matches found:"
    head -20 "$REPORT" | grep -E '^\[|^[a-zA-Z]' | while read -r line; do
        info "    ${line}"
    done
    [[ $TOTAL_HITS -gt 20 ]] && info "    … and $((TOTAL_HITS - 20)) more (see full report)"
else
    info "  No matches found."
fi
info "════════════════════════════════════════════════════════════"
