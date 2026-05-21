#!/usr/bin/env bash
# =============================================================================
# 10-elasticsearch.sh — Single-node Elasticsearch
#
# Purpose:
#   Install and configure Elasticsearch as the shared backend for Arkime,
#   Suricata/Zeek log indexing via Filebeat, and Kibana dashboards.
#
# What this module does:
#   - Add Elastic GPG key and apt repository
#   - Install pinned ES version from versions.conf
#   - Configure single-node discovery (discovery.type: single-node)
#   - Set heap size based on available RAM (via recommended_es_heap)
#   - Optionally disable security/TLS for lab use (ES_DISABLE_SECURITY)
#   - Set up ILM (Index Lifecycle Management) retention policy
#   - Enable and start elasticsearch.service
#   - Wait for ES to be healthy before exiting
#
# Depends on: 00-base
# Config used: ES_HOST, ES_PORT, ES_DISABLE_SECURITY, ES_RETENTION_DAYS
# Idempotent: yes
# =============================================================================

set -euo pipefail
CONF_FILE="$1"; REPO_DIR="$2"
source "${REPO_DIR}/lib/common.sh"
source "$CONF_FILE"

info "Module 10-elasticsearch: starting …"
export DEBIAN_FRONTEND=noninteractive

ES_VERSION=$(get_version elasticsearch)
[[ -z "$ES_VERSION" ]] && ES_VERSION="8.17.0"

# ── 1. Add Elastic GPG key and repository ────────────────────────────────────
KEYRING="/usr/share/keyrings/elasticsearch-keyring.gpg"
REPO_LIST="/etc/apt/sources.list.d/elastic-8.x.list"

if [[ ! -f "$KEYRING" ]]; then
    info "Adding Elastic GPG key …"
    curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
        gpg --dearmor -o "$KEYRING"
else
    info "Elastic GPG key already present."
fi

if [[ ! -f "$REPO_LIST" ]]; then
    info "Adding Elastic 8.x apt repository …"
    echo "deb [signed-by=${KEYRING}] https://artifacts.elastic.co/packages/8.x/apt stable main" \
        | tee "$REPO_LIST" > /dev/null
    apt-get update -qq
else
    info "Elastic apt repository already configured."
fi

# ── 2. Install Elasticsearch ─────────────────────────────────────────────────
if pkg_installed elasticsearch; then
    info "Elasticsearch already installed."
else
    info "Installing Elasticsearch ${ES_VERSION} …"
    apt-get install -y -qq "elasticsearch=${ES_VERSION}"
fi

# Prevent apt from auto-upgrading ES (version pinned)
if [[ ! -f /etc/apt/preferences.d/elasticsearch ]]; then
    cat > /etc/apt/preferences.d/elasticsearch <<EOF
Package: elasticsearch
Pin: version ${ES_VERSION}
Pin-Priority: 1000
EOF
    info "Pinned Elasticsearch to version ${ES_VERSION}."
fi

# ── 3. Configure elasticsearch.yml ───────────────────────────────────────────
ES_CONF="/etc/elasticsearch/elasticsearch.yml"
backup_file "$ES_CONF"

info "Writing elasticsearch.yml …"
cat > "$ES_CONF" <<EOF
# st0ne_buntu — Elasticsearch configuration
# Single-node lab/utility setup

cluster.name: st0ne_buntu
node.name: \${HOSTNAME}

path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

network.host: ${ES_HOST}
http.port: ${ES_PORT}

# Single-node — no discovery needed
discovery.type: single-node

# Allow Arkime and other local tools to manage indices
action.destructive_requires_name: false
EOF

# Disable security/TLS for lab use if configured
if [[ "${ES_DISABLE_SECURITY:-N}" =~ ^[Yy] ]]; then
    info "Disabling ES security (lab mode) …"
    cat >> "$ES_CONF" <<EOF

# Security disabled for lab use — do NOT use in production
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
EOF
else
    info "ES security left at defaults (enabled)."
fi

# ── 4. Set JVM heap size ─────────────────────────────────────────────────────
ES_HEAP=$(recommended_es_heap)
JVM_OPTIONS_DIR="/etc/elasticsearch/jvm.options.d"
HEAP_CONF="${JVM_OPTIONS_DIR}/st0ne_buntu-heap.options"

mkdir -p "$JVM_OPTIONS_DIR"
info "Setting ES heap to ${ES_HEAP} …"
cat > "$HEAP_CONF" <<EOF
# st0ne_buntu — heap sized to $(total_ram_mb) MB total RAM
-Xms${ES_HEAP}
-Xmx${ES_HEAP}
EOF

# ── 5. Systemd overrides (memlock, fd limits) ────────────────────────────────
ES_OVERRIDE_DIR="/etc/systemd/system/elasticsearch.service.d"
ES_OVERRIDE="${ES_OVERRIDE_DIR}/st0ne_buntu.conf"

if [[ ! -f "$ES_OVERRIDE" ]]; then
    info "Adding systemd overrides for ES …"
    mkdir -p "$ES_OVERRIDE_DIR"
    cat > "$ES_OVERRIDE" <<EOF
[Service]
LimitNOFILE=65536
LimitMEMLOCK=infinity
EOF
    systemctl daemon-reload
fi

# ── 6. Enable and start Elasticsearch ────────────────────────────────────────
info "Enabling Elasticsearch service …"
systemctl enable elasticsearch

info "Starting Elasticsearch …"
systemctl restart elasticsearch

# ── 7. Wait for ES to be healthy ─────────────────────────────────────────────
info "Waiting for Elasticsearch to respond …"
ES_URL="http://${ES_HOST}:${ES_PORT}"
MAX_WAIT=60
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
    if curl -sf "${ES_URL}/_cluster/health" > /dev/null 2>&1; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo -n "."
done
echo ""

if curl -sf "${ES_URL}/_cluster/health" > /dev/null 2>&1; then
    ES_STATUS=$(curl -sf "${ES_URL}/_cluster/health" | jq -r '.status')
    info "Elasticsearch is up — cluster status: ${ES_STATUS}"
else
    warn "Elasticsearch did not respond within ${MAX_WAIT}s."
    warn "Check logs: journalctl -u elasticsearch --no-pager -n 50"
    warn "Continuing — downstream modules will fail if ES is not running."
fi

# ── 8. Create ILM policy for log retention ───────────────────────────────────
if curl -sf "${ES_URL}/_cluster/health" > /dev/null 2>&1; then
    info "Creating ILM policy (${ES_RETENTION_DAYS}-day retention) …"
    curl -sf -X PUT "${ES_URL}/_ilm/policy/st0ne_buntu_retention" \
        -H 'Content-Type: application/json' \
        -d "{
            \"policy\": {
                \"phases\": {
                    \"hot\": {
                        \"min_age\": \"0ms\",
                        \"actions\": {}
                    },
                    \"delete\": {
                        \"min_age\": \"${ES_RETENTION_DAYS}d\",
                        \"actions\": {
                            \"delete\": {}
                        }
                    }
                }
            }
        }" > /dev/null 2>&1 && info "ILM policy created." || warn "ILM policy creation failed — set up manually."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log "10-elasticsearch completed"
info "Module 10-elasticsearch complete."
