#!/usr/bin/env bash
# =============================================================================
# burn-range.sh — st0ne_buntu data reset script
# Wipes all SIEM logs, Arkime PCAPs, and sensor log files to provide a clean
# slate for the next live-fire rehearsal.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

[[ "$EUID" -ne 0 ]] && error "Please run with sudo."

banner "Burning Down the Range (Data Reset)"

# ── 1. Stop Services to Release File Locks ───────────────────────────────────
info "Stopping monitoring services …"
systemctl stop filebeat suricata arkimecapture 2>/dev/null || true
if [[ -x "/opt/zeek/bin/zeekctl" ]]; then
    /opt/zeek/bin/zeekctl stop >/dev/null 2>&1 || true
fi

# ── 2. Nuke Elasticsearch Indices ────────────────────────────────────────────
info "Purging Elasticsearch data (SIEM Logs & Arkime Sessions) …"
# Wipe Filebeat and Elastic Agent data streams
curl -s -X DELETE "http://localhost:9200/filebeat-*" > /dev/null || true
curl -s -X DELETE "http://localhost:9200/*logs-zeek*" > /dev/null || true
curl -s -X DELETE "http://localhost:9200/*logs-suricata*" > /dev/null || true

# Wipe Arkime session data (preserves your Arkime user accounts & config)
curl -s -X DELETE "http://localhost:9200/sessions3-*" > /dev/null || true
curl -s -X DELETE "http://localhost:9200/sessions2-*" > /dev/null || true

# ── 3. Erase Disk Logs & PCAPs ───────────────────────────────────────────────
info "Scrubbing raw sensor logs and PCAPs from disk …"
# Suricata
rm -f /var/log/suricata/*.json
rm -f /var/log/suricata/*.log

# Zeek (Current and Date-Archived)
rm -rf /opt/zeek/logs/20* 2>/dev/null || true
rm -f /opt/zeek/logs/current/* 2>/dev/null || true

# Arkime Raw PCAPs
rm -rf /opt/arkime/raw/* 2>/dev/null || true

# ── 4. Reset Pipeline ────────────────────────────────────────────────────────
info "Restarting log shipper …"
systemctl start filebeat

echo ""
info "Range is clean! Your dashboards are empty and ready for the next injection."
