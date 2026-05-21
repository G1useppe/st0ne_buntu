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

info "Module 10-elasticsearch: not yet implemented"
# TODO: implement
