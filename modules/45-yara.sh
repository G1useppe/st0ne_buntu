#!/usr/bin/env bash
# =============================================================================
# 45-yara.sh — YARA malware/pattern matching
#
# Purpose:
#   Install YARA for file and memory scanning against community and custom
#   rule sets.
#
# What this module does:
#   - Install YARA from apt
#   - Install yara-python for scripting
#   - Download community rulesets:
#       * Florian Roth's signature-base
#       * YARA-Forge curated rules
#   - Set up daily cron for rule updates
#   - Create evidence directories for samples and scan output
#
# Depends on: 00-base
# Config used: YARA_HITS_DIR, SAMPLES_DIR
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 45-yara: starting …"
export DEBIAN_FRONTEND=noninteractive

YARA_RULES_DIR="/opt/yara-rules"

# ── 1. Install YARA ─────────────────────────────────────────────────────────
if cmd_exists yara; then
    info "YARA already installed."
else
    info "Installing YARA …"
    apt_install yara
fi

YARA_VER=$(yara --version 2>/dev/null || echo "unknown")
info "YARA version: ${YARA_VER}"

# ── 2. Install yara-python ──────────────────────────────────────────────────
if python3 -c "import yara" 2>/dev/null; then
    info "yara-python already installed."
else
    info "Installing yara-python …"
    pip3 install yara-python --break-system-packages -q 2>/dev/null || \
        apt_install python3-yara 2>/dev/null || \
        warn "Could not install yara-python. Manual scanning still works."
fi

# ── 3. Download community rulesets ───────────────────────────────────────────
mkdir -p "$YARA_RULES_DIR"

# signature-base (Florian Roth / Neo23x0)
if [[ -d "${YARA_RULES_DIR}/signature-base" ]]; then
    info "Updating signature-base rules …"
    git -C "${YARA_RULES_DIR}/signature-base" pull --quiet 2>&1 || \
        warn "signature-base update failed — may need manual pull."
else
    info "Cloning signature-base rules …"
    git clone --quiet --depth 1 https://github.com/Neo23x0/signature-base.git \
        "${YARA_RULES_DIR}/signature-base" 2>&1 || \
        warn "signature-base clone failed."
fi

SIG_COUNT=$(find "${YARA_RULES_DIR}/signature-base" -name '*.yar' 2>/dev/null | wc -l)
info "signature-base rules: ${SIG_COUNT} files"

# YARA-Forge (pre-compiled community rule packs)
YARAFORGE_DIR="${YARA_RULES_DIR}/yara-forge"
mkdir -p "$YARAFORGE_DIR"

info "Downloading YARA-Forge rules …"
if curl -fsSL "https://github.com/YARAHQ/yara-forge/releases/latest/download/yara-forge-rules-full.zip" \
    -o "${YARAFORGE_DIR}/yara-forge-rules.zip" 2>/dev/null; then
    unzip -qo "${YARAFORGE_DIR}/yara-forge-rules.zip" -d "$YARAFORGE_DIR" 2>/dev/null || true
    rm -f "${YARAFORGE_DIR}/yara-forge-rules.zip"
    FORGE_COUNT=$(find "$YARAFORGE_DIR" -name '*.yar' 2>/dev/null | wc -l)
    info "YARA-Forge rules: ${FORGE_COUNT} files"
else
    warn "YARA-Forge download failed. Rules can be added manually."
fi

# ── 4. Create evidence directories ──────────────────────────────────────────
mkdir -p "${YARA_HITS_DIR}" "${SAMPLES_DIR}"
info "Samples dir: ${SAMPLES_DIR}"
info "Scan output: ${YARA_HITS_DIR}"

# ── 5. Daily rule update cron ───────────────────────────────────────────────
CRON_FILE="/etc/cron.daily/st0ne_buntu-yara-update"
if [[ ! -f "$CRON_FILE" ]]; then
    info "Creating daily YARA rule update cron …"
    cp "${REPO_DIR}/rules/update-yara.sh" "$CRON_FILE"
    chmod 755 "$CRON_FILE"
fi

# ── 6. Smoke test ───────────────────────────────────────────────────────────
info "Running smoke test …"
SMOKE_DIR="/tmp/yara-smoke-test"
rm -rf "$SMOKE_DIR" && mkdir -p "$SMOKE_DIR"

# Create a test rule and a matching file
cat > "${SMOKE_DIR}/test.yar" <<'YARA'
rule smoke_test {
    strings:
        $s = "st0ne_buntu_yara_test"
    condition:
        $s
}
YARA
echo "st0ne_buntu_yara_test" > "${SMOKE_DIR}/testfile.txt"

if yara "${SMOKE_DIR}/test.yar" "${SMOKE_DIR}/testfile.txt" 2>/dev/null | grep -q "smoke_test"; then
    info "Smoke test PASSED — YARA matched test rule."
else
    warn "Smoke test failed."
fi

rm -rf "$SMOKE_DIR"

# ── Done ─────────────────────────────────────────────────────────────────────
log "45-yara completed"
info "Module 45-yara complete."
info "Rules:  ${YARA_RULES_DIR}/"
info "Usage:  yara -r ${YARA_RULES_DIR}/signature-base/yara/crime_emotet.yar ${SAMPLES_DIR}/"
info "        yara -r ${YARA_RULES_DIR}/yara-forge/*.yar ${SAMPLES_DIR}/"
