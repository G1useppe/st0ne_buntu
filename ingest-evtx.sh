#!/usr/bin/env bash
# =============================================================================
# ingest-evtx.sh — Parse EVTX files with Hayabusa and ingest into Elasticsearch
#
# Usage:
#   sudo ./ingest-evtx.sh <case-name> [evtx-directory]
#   sudo ./ingest-evtx.sh CASE-001                          # uses evidence/evtx/
#   sudo ./ingest-evtx.sh CASE-001 /path/to/evtx/files
#   sudo ./ingest-evtx.sh CASE-001 /mnt/evidence/image/Windows/System32/winevt/Logs
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

# ── Parse arguments ──────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <case-name> [evtx-directory]"
    echo ""
    echo "  case-name        Used for ES index name and output files"
    echo "  evtx-directory    Path to EVTX files (default: evidence/evtx/)"
    exit 1
fi

CASE_NAME="$1"
EVTX_INPUT="${2:-${EVTX_DIR:-/opt/st0ne_buntu/evidence/evtx}}"
ES_URL="http://${ES_HOST:-localhost}:${ES_PORT:-9200}"
ES_INDEX="st0ne_buntu-case-$(echo "$CASE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
OUTPUT_DIR="${EVTX_DIR:-/opt/st0ne_buntu/evidence/evtx}/${CASE_NAME}-results"

# ── Preflight ────────────────────────────────────────────────────────────────
command -v hayabusa &>/dev/null || error "Hayabusa not found. Run install.sh --module 40 first."
[[ -d "$EVTX_INPUT" ]] || error "EVTX directory not found: ${EVTX_INPUT}"

EVTX_COUNT=$(find "$EVTX_INPUT" -iname '*.evtx' | wc -l)
[[ $EVTX_COUNT -gt 0 ]] || error "No .evtx files found in ${EVTX_INPUT}"

mkdir -p "$OUTPUT_DIR"

info "════════════════════════════════════════════════════════════"
info "  ingest-evtx.sh — Case: ${CASE_NAME}"
info "  Input:  ${EVTX_INPUT} (${EVTX_COUNT} files)"
info "  Output: ${OUTPUT_DIR}"
info "  ES:     ${ES_INDEX}"
info "════════════════════════════════════════════════════════════"

# ── 1. Run Hayabusa CSV timeline ─────────────────────────────────────────────
info "Running Hayabusa CSV timeline …"
CSV_OUT="${OUTPUT_DIR}/hayabusa-alerts.csv"
hayabusa csv-timeline -d "$EVTX_INPUT" -o "$CSV_OUT" -m low -q 2>/dev/null || \
    warn "Hayabusa CSV timeline had issues."

if [[ -s "$CSV_OUT" ]]; then
    CSV_COUNT=$(wc -l < "$CSV_OUT")
    info "CSV timeline: ${CSV_COUNT} entries → ${CSV_OUT}"
fi

# ── 2. Run Hayabusa JSON timeline ────────────────────────────────────────────
info "Running Hayabusa JSON timeline …"
JSONL_OUT="${OUTPUT_DIR}/hayabusa-timeline.jsonl"
hayabusa json-timeline -d "$EVTX_INPUT" -o "$JSONL_OUT" -L -q 2>/dev/null || \
    warn "Hayabusa JSON timeline had issues."

if [[ -s "$JSONL_OUT" ]]; then
    JSON_COUNT=$(wc -l < "$JSONL_OUT")
    info "JSON timeline: ${JSON_COUNT} entries → ${JSONL_OUT}"
fi

# ── 3. Ingest into Elasticsearch ─────────────────────────────────────────────
if curl -sf "${ES_URL}/_cluster/health" > /dev/null 2>&1; then
    if [[ -s "$JSONL_OUT" ]]; then
        info "Ingesting into Elasticsearch index: ${ES_INDEX} …"

        # Add case metadata and bulk insert
        python3 -c "
import json, sys

batch = []
batch_size = 500
count = 0

for line in open('${JSONL_OUT}'):
    line = line.strip()
    if not line:
        continue
    try:
        doc = json.loads(line)
    except json.JSONDecodeError:
        continue

    doc['source_tool'] = 'hayabusa'
    doc['case_id'] = '${CASE_NAME}'
    batch.append(json.dumps({'index': {}}))
    batch.append(json.dumps(doc))
    count += 1

    # Flush in batches
    if len(batch) >= batch_size * 2:
        print('\n'.join(batch))
        print()
        batch = []

# Final flush
if batch:
    print('\n'.join(batch))
    print()

import sys
print(f'Prepared {count} documents for ingest', file=sys.stderr)
" 2>"${OUTPUT_DIR}/ingest.log" | \
        curl -sf -X POST "${ES_URL}/${ES_INDEX}/_bulk" \
            -H 'Content-Type: application/x-ndjson' \
            --data-binary @- > /dev/null 2>&1

        info "Ingested into ${ES_INDEX}."
    fi
else
    warn "Elasticsearch not reachable — skipping ingest."
    warn "Results are still available locally in ${OUTPUT_DIR}/"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "════════════════════════════════════════════════════════════"
info "  EVTX analysis complete — Case: ${CASE_NAME}"
info "  EVTX files processed: ${EVTX_COUNT}"
info ""
info "  Local results:"
info "    CSV:  ${CSV_OUT}"
info "    JSON: ${JSONL_OUT}"
info ""
info "  Elasticsearch:"
info "    Index: ${ES_INDEX}"
info "    Kibana: http://localhost:${KIBANA_PORT:-5601}/app/discover"
info ""
info "  Quick analysis:"
info "    head -20 ${CSV_OUT} | csvlook"
info "    curl -s '${ES_URL}/${ES_INDEX}/_search?q=Level:critical&size=10' | jq '.hits.hits[]._source'"
info "════════════════════════════════════════════════════════════"
