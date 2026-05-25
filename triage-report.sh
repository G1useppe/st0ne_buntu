#!/usr/bin/env bash
# =============================================================================
# triage-report.sh — Generate a consolidated case triage report
#
# Pulls together all available evidence for a case and produces a markdown
# summary report. Checks local results directories, Elasticsearch indices,
# and Arkime sessions.
#
# Usage:
#   sudo ./triage-report.sh <case-name>
#   sudo ./triage-report.sh CASE-001
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

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <case-name>"
    exit 1
fi

CASE_NAME="$1"
ES_URL="http://${ES_HOST:-localhost}:${ES_PORT:-9200}"
ES_INDEX="st0ne_buntu-case-$(echo "$CASE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
EVIDENCE_BASE="${EVIDENCE_DIR:-/opt/st0ne_buntu/evidence}"
KAPE_RESULTS="${KAPE_DIR:-${EVIDENCE_BASE}/kape-output}/${CASE_NAME}-results"
EVTX_RESULTS="${EVTX_DIR:-${EVIDENCE_BASE}/evtx}/${CASE_NAME}-results"
PCAP_RESULTS="${EVIDENCE_BASE}/processed"
YARA_RESULTS="${YARA_HITS_DIR:-${EVIDENCE_BASE}/yara-hits}"

REPORT_DIR="${EVIDENCE_BASE}/reports"
mkdir -p "$REPORT_DIR"
REPORT="${REPORT_DIR}/${CASE_NAME}-triage-$(date '+%Y%m%d-%H%M%S').md"

info "════════════════════════════════════════════════════════════"
info "  Triage Report — Case: ${CASE_NAME}"
info "════════════════════════════════════════════════════════════"

# ── Start report ─────────────────────────────────────────────────────────────
cat > "$REPORT" <<EOF
# Triage Report: ${CASE_NAME}

**Generated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')
**Analyst:** $(whoami)@$(hostname)
**Workstation:** st0ne_buntu

---

EOF

# ── Elasticsearch data ───────────────────────────────────────────────────────
ES_AVAILABLE=false
if curl -sf "${ES_URL}/_cluster/health" > /dev/null 2>&1; then
    ES_AVAILABLE=true
fi

if [[ "$ES_AVAILABLE" == true ]]; then
    ES_DOC_COUNT=$(curl -sf "${ES_URL}/${ES_INDEX}/_count" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

    if [[ "$ES_DOC_COUNT" -gt 0 ]]; then
        info "ES index ${ES_INDEX}: ${ES_DOC_COUNT} documents"

        cat >> "$REPORT" <<EOF
## Elasticsearch Summary

- **Index:** \`${ES_INDEX}\`
- **Total documents:** ${ES_DOC_COUNT}

EOF

        # Breakdown by source_tool
        TOOL_BREAKDOWN=$(curl -sf -X POST "${ES_URL}/${ES_INDEX}/_search" \
            -H 'Content-Type: application/json' \
            -d '{"size":0,"aggs":{"tools":{"terms":{"field":"source_tool.keyword","size":20}}}}' 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
buckets = data.get('aggregations',{}).get('tools',{}).get('buckets',[])
for b in buckets:
    print(f'| {b[\"key\"]} | {b[\"doc_count\"]} |')
" 2>/dev/null || echo "| Unable to query | - |")

        cat >> "$REPORT" <<EOF
### Documents by Source

| Source Tool | Count |
|-------------|-------|
${TOOL_BREAKDOWN}

EOF

        # High-severity Hayabusa findings
        HIGH_SEV=$(curl -sf -X POST "${ES_URL}/${ES_INDEX}/_search" \
            -H 'Content-Type: application/json' \
            -d '{"size":20,"query":{"bool":{"must":[{"term":{"source_tool.keyword":"hayabusa"}},{"terms":{"Level.keyword":["critical","high"]}}]}},"sort":[{"@timestamp":"asc"}]}' 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
hits = data.get('hits',{}).get('hits',[])
for h in hits:
    s = h['_source']
    ts = s.get('@timestamp','?')
    level = s.get('Level','?')
    title = s.get('RuleTitle', s.get('rule_title', s.get('Title','?')))
    print(f'| {ts} | {level} | {title} |')
" 2>/dev/null || echo "")

        if [[ -n "$HIGH_SEV" ]]; then
            cat >> "$REPORT" <<EOF
### High/Critical Hayabusa Detections

| Timestamp | Level | Rule |
|-----------|-------|------|
${HIGH_SEV}

EOF
        fi
    else
        echo "No data found in ES index \`${ES_INDEX}\`." >> "$REPORT"
        echo "" >> "$REPORT"
    fi
fi

# ── Suricata alerts from PCAP processing ─────────────────────────────────────
SURI_ALERTS=""
if [[ -d "$PCAP_RESULTS" ]]; then
    ALERT_FILES=$(find "$PCAP_RESULTS" -name 'fast.log' -size +0c 2>/dev/null)
    if [[ -n "$ALERT_FILES" ]]; then
        TOTAL_ALERTS=0
        while IFS= read -r af; do
            count=$(wc -l < "$af")
            TOTAL_ALERTS=$((TOTAL_ALERTS + count))
        done <<< "$ALERT_FILES"

        info "Suricata alerts found: ${TOTAL_ALERTS}"

        cat >> "$REPORT" <<EOF
## Network Analysis (Suricata)

**Total alerts:** ${TOTAL_ALERTS}

### Top Alert Signatures

\`\`\`
$(cat ${PCAP_RESULTS}/*/suricata/fast.log 2>/dev/null | \
    grep -oP '\[\*\*\] \K[^\[]+' | sort | uniq -c | sort -rn | head -15)
\`\`\`

EOF
    fi
fi

# ── Filebeat data ────────────────────────────────────────────────────────────
if [[ "$ES_AVAILABLE" == true ]]; then
    FB_COUNT=$(curl -sf "${ES_URL}/filebeat-*/_count" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

    if [[ "$FB_COUNT" -gt 0 ]]; then
        cat >> "$REPORT" <<EOF
## Filebeat Data

- **Total documents in filebeat indices:** ${FB_COUNT}
- **Kibana dashboards:** http://localhost:${KIBANA_PORT:-5601}/app/dashboards

EOF
    fi
fi

# ── Arkime sessions ──────────────────────────────────────────────────────────
if [[ "$ES_AVAILABLE" == true ]]; then
    ARKIME_SESSIONS=$(curl -sf "${ES_URL}/arkime_sessions3-*/_count" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

    if [[ "$ARKIME_SESSIONS" -gt 0 ]]; then
        cat >> "$REPORT" <<EOF
## Arkime Sessions

- **Total sessions indexed:** ${ARKIME_SESSIONS}
- **Arkime Viewer:** http://localhost:${ARKIME_PORT:-8005}

EOF
    fi
fi

# ── KAPE results ─────────────────────────────────────────────────────────────
if [[ -d "$KAPE_RESULTS" ]]; then
    info "KAPE results found at ${KAPE_RESULTS}"

    cat >> "$REPORT" <<EOF
## Host Artifacts (KAPE)

**Results directory:** \`${KAPE_RESULTS}\`

EOF

    # Registry highlights
    REG_DIR="${KAPE_RESULTS}/registry"
    if [[ -d "$REG_DIR" ]] && ls "$REG_DIR"/*-report.txt &>/dev/null; then
        cat >> "$REPORT" <<EOF
### Registry Highlights

\`\`\`
$(grep -hri 'run\|service\|schedule\|startup\|userassist\|lastwrite' \
    "$REG_DIR"/*-report.txt 2>/dev/null | head -20 || echo "No notable findings")
\`\`\`

EOF
    fi

    # Hayabusa summary from KAPE
    HAYA_CSV="${KAPE_RESULTS}/timeline/hayabusa-alerts.csv"
    if [[ -s "$HAYA_CSV" ]]; then
        HAYA_COUNT=$(wc -l < "$HAYA_CSV")
        cat >> "$REPORT" <<EOF
### Hayabusa Timeline

- **Total detections:** ${HAYA_COUNT}
- **CSV:** \`${HAYA_CSV}\`

EOF
    fi
fi

# ── YARA scan results ───────────────────────────────────────────────────────
YARA_SCANS=$(find "$YARA_RESULTS" -name 'scan-*.txt' -size +0c 2>/dev/null | sort -r | head -1)
if [[ -n "$YARA_SCANS" ]]; then
    YARA_HITS=$(grep -cE '^\[|^[a-zA-Z]' "$YARA_SCANS" 2>/dev/null || echo 0)
    info "Latest YARA scan: ${YARA_HITS} hits"

    cat >> "$REPORT" <<EOF
## YARA Scan Results

**Latest scan:** \`${YARA_SCANS}\`
**Hits:** ${YARA_HITS}

\`\`\`
$(head -20 "$YARA_SCANS" | grep -E '^\[|^[a-zA-Z]' || echo "No matches")
\`\`\`

EOF
fi

# ── Links and next steps ────────────────────────────────────────────────────
cat >> "$REPORT" <<EOF
---

## Quick Access

| Tool | URL |
|------|-----|
| Kibana | http://localhost:${KIBANA_PORT:-5601} |
| Arkime | http://localhost:${ARKIME_PORT:-8005} |
| CyberChef | http://localhost:8888/CyberChef.html |

## ES Queries

\`\`\`bash
# All case data
curl -s '${ES_URL}/${ES_INDEX}/_search?size=10' | jq '.hits.hits[]._source'

# High-severity detections
curl -s '${ES_URL}/${ES_INDEX}/_search?q=Level:critical+OR+Level:high&size=20' | jq '.hits.hits[]._source'

# Suricata alerts
curl -s '${ES_URL}/filebeat-*/_search?q=event.kind:alert&size=20' | jq '.hits.hits[]._source'
\`\`\`
EOF

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
info "════════════════════════════════════════════════════════════"
info "  Triage report generated"
info "  Report: ${REPORT}"
info ""
info "  View: cat ${REPORT}"
info "════════════════════════════════════════════════════════════"
