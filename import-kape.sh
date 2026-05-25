#!/usr/bin/env bash
# =============================================================================
# import-kape.sh — Parse KAPE triage output and ingest into Elasticsearch
#
# Usage:
#   sudo ./import-kape.sh <case-name> [kape-directory]
#   sudo ./import-kape.sh CASE-001 /opt/st0ne_buntu/evidence/kape-output/CASE-001
#   sudo ./import-kape.sh CASE-001   # defaults to evidence/kape-output/CASE-001/
#   sudo ./import-kape.sh CASE-001 /mnt/evidence/image  # mounted forensic image
#
# Depends on: 50-kape (parsers), 10-elasticsearch
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
    echo "Usage: $0 <case-name> [kape-directory]"
    echo ""
    echo "  case-name        Used for ES index name and output directory"
    echo "  kape-directory    Path to KAPE collection (default: evidence/kape-output/<case-name>/)"
    exit 1
fi

CASE_NAME="$1"
KAPE_INPUT="${2:-${KAPE_DIR:-/opt/st0ne_buntu/evidence/kape-output}/${CASE_NAME}}"
RESULTS_DIR="${KAPE_DIR:-/opt/st0ne_buntu/evidence/kape-output}/${CASE_NAME}-results"
ES_URL="http://${ES_HOST:-localhost}:${ES_PORT:-9200}"
ES_INDEX="st0ne_buntu-case-$(echo "$CASE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"

[[ -d "$KAPE_INPUT" ]] || error "KAPE input directory not found: ${KAPE_INPUT}"

info "════════════════════════════════════════════════════════════"
info "  import-kape.sh — Case: ${CASE_NAME}"
info "  Input:  ${KAPE_INPUT}"
info "  Output: ${RESULTS_DIR}"
info "  ES:     ${ES_INDEX}"
info "════════════════════════════════════════════════════════════"

# Create output directories
mkdir -p "${RESULTS_DIR}"/{timeline,registry,browser,ese,prefetch}

# Track what we find and process
ARTIFACTS_FOUND=0
ARTIFACTS_PARSED=0

# ── Helper: bulk insert JSONL into Elasticsearch ─────────────────────────────
es_bulk_insert() {
    local jsonl_file="$1"
    local source_tool="$2"

    if ! curl -sf "${ES_URL}/_cluster/health" > /dev/null 2>&1; then
        warn "Elasticsearch not reachable — skipping ingest for ${source_tool}."
        return
    fi

    if [[ ! -s "$jsonl_file" ]]; then
        warn "Empty JSONL file — skipping ingest for ${source_tool}."
        return
    fi

    info "Ingesting ${source_tool} data into ${ES_INDEX} …"

    # Add source_tool and case_id fields, then format for bulk API
    python3 -c "
import json, sys

for line in open('${jsonl_file}'):
    line = line.strip()
    if not line:
        continue
    try:
        doc = json.loads(line)
    except json.JSONDecodeError:
        continue
    doc['source_tool'] = '${source_tool}'
    doc['case_id'] = '${CASE_NAME}'
    print(json.dumps({'index': {}}))
    print(json.dumps(doc))
" | curl -sf -X POST "${ES_URL}/${ES_INDEX}/_bulk" \
        -H 'Content-Type: application/x-ndjson' \
        --data-binary @- > /dev/null 2>&1

    local count
    count=$(wc -l < "$jsonl_file")
    info "  Ingested ${count} records from ${source_tool}."
}

# ── 1. Scan for artifacts ────────────────────────────────────────────────────
info "Scanning for artifacts …"

EVTX_FILES=$(find "$KAPE_INPUT" -iname '*.evtx' 2>/dev/null)
EVTX_COUNT=$(echo "$EVTX_FILES" | grep -c '.' 2>/dev/null || echo 0)
[[ $EVTX_COUNT -gt 0 ]] && info "  EVTX files: ${EVTX_COUNT}" && ARTIFACTS_FOUND=$((ARTIFACTS_FOUND + 1))

REG_HIVES=$(find "$KAPE_INPUT" -maxdepth 5 -type f \( \
    -iname 'SYSTEM' -o -iname 'SOFTWARE' -o -iname 'SAM' -o \
    -iname 'SECURITY' -o -iname 'NTUSER.DAT' -o -iname 'UsrClass.dat' \
    \) 2>/dev/null | head -20)
REG_COUNT=$(echo "$REG_HIVES" | grep -c '.' 2>/dev/null || echo 0)
[[ $REG_COUNT -gt 0 ]] && info "  Registry hives: ${REG_COUNT}" && ARTIFACTS_FOUND=$((ARTIFACTS_FOUND + 1))

MFT_FILES=$(find "$KAPE_INPUT" -maxdepth 5 -type f \( -iname '$MFT' -o -iname 'MFT' \) 2>/dev/null)
MFT_COUNT=$(echo "$MFT_FILES" | grep -c '.' 2>/dev/null || echo 0)
[[ $MFT_COUNT -gt 0 ]] && info "  MFT files: ${MFT_COUNT}" && ARTIFACTS_FOUND=$((ARTIFACTS_FOUND + 1))

CHROME_PROFILES=$(find "$KAPE_INPUT" -maxdepth 8 -type f -iname 'History' -path '*/Google/Chrome/*' 2>/dev/null)
CHROME_COUNT=$(echo "$CHROME_PROFILES" | grep -c '.' 2>/dev/null || echo 0)
[[ $CHROME_COUNT -gt 0 ]] && info "  Chrome profiles: ${CHROME_COUNT}" && ARTIFACTS_FOUND=$((ARTIFACTS_FOUND + 1))

ESE_FILES=$(find "$KAPE_INPUT" -maxdepth 5 -type f \( -iname 'SRUDB.dat' -o -iname 'qmgr*.dat' \) 2>/dev/null)
ESE_COUNT=$(echo "$ESE_FILES" | grep -c '.' 2>/dev/null || echo 0)
[[ $ESE_COUNT -gt 0 ]] && info "  ESE databases: ${ESE_COUNT}" && ARTIFACTS_FOUND=$((ARTIFACTS_FOUND + 1))

PF_FILES=$(find "$KAPE_INPUT" -maxdepth 5 -type f -iname '*.pf' 2>/dev/null)
PF_COUNT=$(echo "$PF_FILES" | grep -c '.' 2>/dev/null || echo 0)
[[ $PF_COUNT -gt 0 ]] && info "  Prefetch files: ${PF_COUNT}" && ARTIFACTS_FOUND=$((ARTIFACTS_FOUND + 1))

if [[ $ARTIFACTS_FOUND -eq 0 ]]; then
    warn "No recognised artifacts found in ${KAPE_INPUT}."
    warn "Ensure the KAPE collection or mounted image contains Windows artifacts."
    exit 0
fi

# ── 2. Parse EVTX with Hayabusa ──────────────────────────────────────────────
if [[ $EVTX_COUNT -gt 0 ]] && command -v hayabusa &>/dev/null; then
    info "━━━ Parsing EVTX files with Hayabusa …"

    # Find the directory containing EVTX files
    EVTX_DIR=$(dirname "$(echo "$EVTX_FILES" | head -1)")

    # CSV timeline (human-readable)
    hayabusa csv-timeline -d "$KAPE_INPUT" -o "${RESULTS_DIR}/timeline/hayabusa-alerts.csv" \
        -m low -q 2>/dev/null || warn "Hayabusa CSV timeline had issues."

    # JSONL timeline (for ES ingest)
    hayabusa json-timeline -d "$KAPE_INPUT" -o "${RESULTS_DIR}/timeline/hayabusa-timeline.jsonl" \
        -L -q 2>/dev/null || warn "Hayabusa JSON timeline had issues."

    if [[ -s "${RESULTS_DIR}/timeline/hayabusa-alerts.csv" ]]; then
        ALERT_COUNT=$(wc -l < "${RESULTS_DIR}/timeline/hayabusa-alerts.csv")
        info "  Hayabusa: ${ALERT_COUNT} timeline entries"
        ARTIFACTS_PARSED=$((ARTIFACTS_PARSED + 1))
    fi

    # Ingest into ES
    if [[ -s "${RESULTS_DIR}/timeline/hayabusa-timeline.jsonl" ]]; then
        es_bulk_insert "${RESULTS_DIR}/timeline/hayabusa-timeline.jsonl" "hayabusa"
    fi
elif [[ $EVTX_COUNT -gt 0 ]]; then
    warn "EVTX files found but Hayabusa not installed. Skipping."
fi

# ── 3. Parse registry hives with RegRipper ───────────────────────────────────
if [[ $REG_COUNT -gt 0 ]]; then
    info "━━━ Parsing registry hives with RegRipper …"

    while IFS= read -r hive; do
        [[ -z "$hive" ]] && continue
        HIVE_NAME=$(basename "$hive")
        HIVE_PARENT=$(basename "$(dirname "$hive")")

        # Determine the appropriate RegRipper plugin
        case "${HIVE_NAME,,}" in
            system)      PROFILE="system" ;;
            software)    PROFILE="software" ;;
            sam)         PROFILE="sam" ;;
            security)    PROFILE="security" ;;
            ntuser.dat)  PROFILE="ntuser"; HIVE_NAME="NTUSER-${HIVE_PARENT}" ;;
            usrclass.dat) PROFILE="usrclass"; HIVE_NAME="UsrClass-${HIVE_PARENT}" ;;
            *)           PROFILE=""; ;;
        esac

        OUTPUT_FILE="${RESULTS_DIR}/registry/${HIVE_NAME}-report.txt"

        if [[ -n "$PROFILE" ]] && command -v rip.pl &>/dev/null; then
            info "  Parsing: ${HIVE_NAME} (profile: ${PROFILE})"
            rip.pl -r "$hive" -p "$PROFILE" > "$OUTPUT_FILE" 2>/dev/null || \
                warn "  RegRipper failed on ${HIVE_NAME}"
        elif command -v rip.pl &>/dev/null; then
            info "  Parsing: ${HIVE_NAME} (all plugins)"
            rip.pl -r "$hive" -a > "$OUTPUT_FILE" 2>/dev/null || \
                warn "  RegRipper failed on ${HIVE_NAME}"
        fi
    done <<< "$REG_HIVES"

    REG_PARSED=$(find "${RESULTS_DIR}/registry" -name '*-report.txt' -size +0c | wc -l)
    info "  Registry: ${REG_PARSED} hives parsed"
    [[ $REG_PARSED -gt 0 ]] && ARTIFACTS_PARSED=$((ARTIFACTS_PARSED + 1))

    # Convert registry reports to JSONL for ES ingest
    REGRIPPER_JSONL="${RESULTS_DIR}/timeline/registry-findings.jsonl"
    python3 -c "
import json, re, os, datetime

results_dir = '${RESULTS_DIR}/registry'
output = open('${REGRIPPER_JSONL}', 'w')

for fname in os.listdir(results_dir):
    if not fname.endswith('-report.txt'):
        continue
    hive = fname.replace('-report.txt', '')
    filepath = os.path.join(results_dir, fname)
    current_plugin = 'unknown'

    for line in open(filepath, errors='ignore'):
        line = line.strip()
        if not line:
            continue
        # RegRipper plugin headers
        if line.startswith('Launching ') or line.startswith('Plugin:'):
            current_plugin = line.split()[-1] if line.split() else 'unknown'
            continue
        # Try to extract timestamps
        ts_match = re.search(r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})', line)
        timestamp = ts_match.group(1) if ts_match else datetime.datetime.utcnow().isoformat()

        doc = {
            '@timestamp': timestamp,
            'source_tool': 'regripper',
            'registry_hive': hive,
            'plugin': current_plugin,
            'finding': line[:1000]
        }
        output.write(json.dumps(doc) + '\n')

output.close()
" 2>/dev/null || warn "Registry JSONL conversion had issues."

    if [[ -s "$REGRIPPER_JSONL" ]]; then
        es_bulk_insert "$REGRIPPER_JSONL" "regripper"
    fi
fi

# ── 4. Parse $MFT with analyzeMFT ───────────────────────────────────────────
if [[ $MFT_COUNT -gt 0 ]]; then
    info "━━━ Parsing MFT …"

    MFT_FILE=$(echo "$MFT_FILES" | head -1)
    MFT_CSV="${RESULTS_DIR}/timeline/mft-timeline.csv"
    MFT_JSONL="${RESULTS_DIR}/timeline/mft-timeline.jsonl"

    if python3 -c "import analyzemft" 2>/dev/null; then
        python3 -m analyzemft.cli -f "$MFT_FILE" -o "$MFT_CSV" --csv 2>/dev/null || \
            warn "analyzeMFT had issues."

        if [[ -s "$MFT_CSV" ]]; then
            MFT_RECORDS=$(wc -l < "$MFT_CSV")
            info "  MFT: ${MFT_RECORDS} records parsed"
            ARTIFACTS_PARSED=$((ARTIFACTS_PARSED + 1))

            # Convert CSV to JSONL for ES ingest
            python3 -c "
import csv, json

with open('${MFT_CSV}') as f:
    reader = csv.DictReader(f)
    with open('${MFT_JSONL}', 'w') as out:
        for row in reader:
            # Use the earliest available timestamp
            ts = row.get('SI Creation Date', '') or row.get('FN Creation Date', '')
            if ts:
                row['@timestamp'] = ts
            row['source_tool'] = 'mft'
            out.write(json.dumps(row) + '\n')
" 2>/dev/null || warn "MFT JSONL conversion had issues."

            if [[ -s "$MFT_JSONL" ]]; then
                es_bulk_insert "$MFT_JSONL" "mft"
            fi
        fi
    else
        warn "analyzeMFT not installed. Skipping MFT parsing."
    fi
fi

# ── 5. Parse Chrome profiles with Hindsight ──────────────────────────────────
if [[ $CHROME_COUNT -gt 0 ]]; then
    info "━━━ Parsing Chrome profiles with Hindsight …"

    while IFS= read -r history_file; do
        [[ -z "$history_file" ]] && continue
        PROFILE_DIR=$(dirname "$history_file")
        PROFILE_NAME=$(basename "$(dirname "$(dirname "$(dirname "$PROFILE_DIR")")")")
        OUTPUT_NAME="chrome-${PROFILE_NAME}"

        info "  Profile: ${PROFILE_DIR}"

        if python3 -c "import pyhindsight" 2>/dev/null; then
            python3 -m pyhindsight.hindsight -i "$PROFILE_DIR" \
                -o "${RESULTS_DIR}/browser/${OUTPUT_NAME}" \
                -f json 2>/dev/null || \
                warn "  Hindsight had issues with ${PROFILE_DIR}"

            # Look for the output file (Hindsight appends timestamp)
            HINDSIGHT_OUT=$(find "${RESULTS_DIR}/browser/" -name "${OUTPUT_NAME}*" -type f | head -1)
            if [[ -n "$HINDSIGHT_OUT" && -s "$HINDSIGHT_OUT" ]]; then
                info "  Chrome artifacts extracted."
                ARTIFACTS_PARSED=$((ARTIFACTS_PARSED + 1))
            fi
        else
            warn "Hindsight not installed. Skipping Chrome parsing."
            break
        fi
    done <<< "$CHROME_PROFILES"
fi

# ── 6. Parse ESE databases with esedbexport ──────────────────────────────────
if [[ $ESE_COUNT -gt 0 ]] && command -v esedbexport &>/dev/null; then
    info "━━━ Parsing ESE databases …"

    while IFS= read -r ese_file; do
        [[ -z "$ese_file" ]] && continue
        ESE_NAME=$(basename "$ese_file" | tr '.' '-')
        ESE_OUT="${RESULTS_DIR}/ese/${ESE_NAME}"
        mkdir -p "$ESE_OUT"

        info "  Exporting: $(basename "$ese_file")"
        esedbexport -t "$ESE_OUT" "$ese_file" 2>/dev/null || \
            warn "  esedbexport failed on $(basename "$ese_file")"
    done <<< "$ESE_FILES"

    ESE_EXPORTED=$(find "${RESULTS_DIR}/ese" -type f | wc -l)
    [[ $ESE_EXPORTED -gt 0 ]] && ARTIFACTS_PARSED=$((ARTIFACTS_PARSED + 1))
    info "  ESE: ${ESE_EXPORTED} tables exported"
elif [[ $ESE_COUNT -gt 0 ]]; then
    warn "ESE databases found but esedbexport not installed. Skipping."
fi

# ── 7. Parse Prefetch files ──────────────────────────────────────────────────
if [[ $PF_COUNT -gt 0 ]]; then
    info "━━━ Parsing Prefetch files …"

    PF_JSONL="${RESULTS_DIR}/timeline/prefetch-timeline.jsonl"

    if command -v scca_export &>/dev/null; then
        while IFS= read -r pf_file; do
            [[ -z "$pf_file" ]] && continue
            scca_export "$pf_file" 2>/dev/null
        done <<< "$PF_FILES" > "${RESULTS_DIR}/prefetch/prefetch-raw.txt"
        info "  Prefetch: exported with scca_export"
        ARTIFACTS_PARSED=$((ARTIFACTS_PARSED + 1))
    else
        # Fallback: extract basic info with Python
        python3 -c "
import os, json, struct, datetime

pf_dir = '''${PF_FILES}'''
output = open('${PF_JSONL}', 'w')

for pf_path in pf_dir.strip().split('\n'):
    pf_path = pf_path.strip()
    if not pf_path or not os.path.isfile(pf_path):
        continue
    fname = os.path.basename(pf_path)
    exe_name = fname.rsplit('-', 1)[0] if '-' in fname else fname
    try:
        stat = os.stat(pf_path)
        doc = {
            '@timestamp': datetime.datetime.utcfromtimestamp(stat.st_mtime).isoformat(),
            'source_tool': 'prefetch',
            'executable': exe_name,
            'prefetch_file': fname,
            'file_size': stat.st_size
        }
        output.write(json.dumps(doc) + '\n')
    except Exception:
        pass

output.close()
" 2>/dev/null || warn "Prefetch parsing had issues."

        if [[ -s "$PF_JSONL" ]]; then
            PF_PARSED=$(wc -l < "$PF_JSONL")
            info "  Prefetch: ${PF_PARSED} entries (basic metadata)"
            ARTIFACTS_PARSED=$((ARTIFACTS_PARSED + 1))
            es_bulk_insert "$PF_JSONL" "prefetch"
        fi
    fi
fi

# ── 8. Generate summary report ───────────────────────────────────────────────
info "━━━ Generating summary report …"

SUMMARY="${RESULTS_DIR}/summary.md"
cat > "$SUMMARY" <<EOF
# Case Report: ${CASE_NAME}

**Generated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')
**Source:** ${KAPE_INPUT}
**Analyst workstation:** $(hostname)

## Artifacts Processed

| Type | Count | Status |
|------|-------|--------|
| EVTX files | ${EVTX_COUNT} | $([ $EVTX_COUNT -gt 0 ] && echo "Parsed" || echo "Not found") |
| Registry hives | ${REG_COUNT} | $([ $REG_COUNT -gt 0 ] && echo "Parsed" || echo "Not found") |
| MFT files | ${MFT_COUNT} | $([ $MFT_COUNT -gt 0 ] && echo "Parsed" || echo "Not found") |
| Chrome profiles | ${CHROME_COUNT} | $([ $CHROME_COUNT -gt 0 ] && echo "Parsed" || echo "Not found") |
| ESE databases | ${ESE_COUNT} | $([ $ESE_COUNT -gt 0 ] && echo "Parsed" || echo "Not found") |
| Prefetch files | ${PF_COUNT} | $([ $PF_COUNT -gt 0 ] && echo "Parsed" || echo "Not found") |

## Output Locations

- **Hayabusa timeline:** \`${RESULTS_DIR}/timeline/hayabusa-alerts.csv\`
- **Registry reports:** \`${RESULTS_DIR}/registry/\`
- **MFT timeline:** \`${RESULTS_DIR}/timeline/mft-timeline.csv\`
- **Browser artifacts:** \`${RESULTS_DIR}/browser/\`
- **ESE exports:** \`${RESULTS_DIR}/ese/\`

## Elasticsearch

- **Index:** \`${ES_INDEX}\`
- **Kibana:** http://localhost:${KIBANA_PORT:-5601}/app/discover#/?_a=(index:'${ES_INDEX}')

## Quick Analysis Commands

\`\`\`bash
# View Hayabusa high-severity detections
head -50 ${RESULTS_DIR}/timeline/hayabusa-alerts.csv | csvlook

# Search registry reports for persistence
grep -ri 'run\|service\|schedule\|startup' ${RESULTS_DIR}/registry/

# Query ES for this case
curl -s "${ES_URL}/${ES_INDEX}/_search?q=*&size=10" | jq '.hits.hits[]._source'
\`\`\`
EOF

info "Summary written to: ${SUMMARY}"

# ── Final summary ────────────────────────────────────────────────────────────
echo ""
info "════════════════════════════════════════════════════════════"
info "  Case ${CASE_NAME} — import complete"
info "  Artifacts found:  ${ARTIFACTS_FOUND}"
info "  Artifacts parsed: ${ARTIFACTS_PARSED}"
info "  Results:  ${RESULTS_DIR}/"
info "  ES index: ${ES_INDEX}"
info ""
info "  View in Kibana: http://localhost:${KIBANA_PORT:-5601}"
info "  Summary report: ${SUMMARY}"
info "════════════════════════════════════════════════════════════"
