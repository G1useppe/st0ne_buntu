#!/usr/bin/env bash
# =============================================================================
# tests/smoke-test.sh — Post-install smoke tests
#
# Validates that all installed services are running and responsive.
# Run after install.sh completes or any time to health-check the VM.
#
# Usage: sudo ./tests/smoke-test.sh
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_DIR}/lib/common.sh"

PASS=0; FAIL=0

check() {
    local name="$1"; shift
    if "$@" > /dev/null 2>&1; then
        info "PASS: ${name}"
        ((PASS++))
    else
        warn "FAIL: ${name}"
        ((FAIL++))
    fi
}

banner "st0ne_buntu smoke tests"

# Services
check "Elasticsearch running"     systemctl is-active --quiet elasticsearch
check "Kibana running"            systemctl is-active --quiet kibana
check "Suricata running"          systemctl is-active --quiet suricata
check "Filebeat running"          systemctl is-active --quiet filebeat
check "Arkime capture running"    systemctl is-active --quiet arkimecapture
check "Arkime viewer running"     systemctl is-active --quiet arkimeviewer

# HTTP endpoints
check "ES responds on :9200"      curl -sf http://localhost:9200/_cluster/health
check "Kibana responds on :5601"  curl -sf http://localhost:5601/api/status
check "Arkime responds on :8005"  curl -sf http://localhost:8005

# Tools
check "suricata binary"           command -v suricata
check "zeek binary"               command -v zeek
check "hayabusa binary"           command -v hayabusa
check "yara binary"               command -v yara
check "suricata-update binary"    command -v suricata-update

# Rules
check "Suricata rules exist"      test -s /var/lib/suricata/rules/suricata.rules
check "YARA rules exist"          test -d /opt/yara-rules/signature-base

# Suricata alert test
curl -sf http://testmynids.org/uid/index.html -o /dev/null 2>/dev/null || true
sleep 3
check "Suricata test alert fired" grep -q "ET POLICY" /var/log/suricata/fast.log

echo ""
banner "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] && info "All checks passed." || warn "Some checks failed — review above."
exit $FAIL
