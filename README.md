# st0ne_buntu

A modular toolkit for building a standardised Ubuntu 22.04 LTS forensics and network security monitoring workstation. Clone the repo on a fresh install, run the installer, and get a fully configured stack ready for PCAP analysis, threat hunting, and incident response.

## What you get

| Tool | Purpose | Module |
|---|---|---|
| **Elasticsearch 8.x** | Shared indexing backend for all log/session data | `10-elasticsearch` |
| **Kibana** | Dashboards, Elastic Security SIEM, alert triage | `15-kibana` |
| **Suricata** | Signature-based IDS with full ET Open ruleset (daily updates) | `20-suricata` |
| **Zeek** | Protocol analysis, connection logging, behavioural detection | `25-zeek` |
| **Filebeat** | Ships Suricata + Zeek logs into Elasticsearch | `30-filebeat` |
| **Arkime** | Full packet capture with indexed session search | `35-arkime` |
| **Hayabusa** | Fast Windows EVTX analysis with Sigma rules | `40-hayabusa` |
| **YARA** | File/malware pattern matching with community rulesets | `45-yara` |
| **KAPE parsers** | Windows forensic artifact parsers (Linux-side) | `50-kape` |

## Quick start

```bash
git clone https://github.com/G1useppe/st0ne_buntu.git
cd st0ne_buntu
sudo ./install.sh
```

On first run you'll be prompted for network interface (defaults to `lo` for offline PCAP analysis), HOME_NET (defaults to `any`), and storage preferences. These are saved to `st0ne_buntu.conf` (gitignored — each team member gets their own).

## Requirements

- **OS:** Ubuntu 22.04 LTS (also tested on 24.04)
- **RAM:** 16 GB recommended, 8 GB minimum (constrained mode)
- **Disk:** 80 GB+ free (PCAP storage is configurable)
- **CPU:** 4+ cores recommended
- **Network:** Internet access during install (for packages and rules)

## Repo structure

```
st0ne_buntu/
├── install.sh              # Orchestrator — runs modules in order
├── process-pcaps.sh        # Batch Suricata + Zeek against PCAPs
├── st0ne_buntu.conf        # Local config (generated, gitignored)
├── versions.conf           # Pinned tool versions
├── .gitignore
│
├── assets/
│   └── wallpaper.png       # st0ne_buntu desktop wallpaper
│
├── lib/
│   ├── common.sh           # Shared functions, colours, helpers
│   ├── preflight.sh        # Pre-install validation
│   └── configure.sh        # First-run config generator
│
├── modules/
│   ├── 00-base.sh          # System deps, sysctl, wallpaper, geany
│   ├── 10-elasticsearch.sh # Single-node ES, heap tuning, ILM
│   ├── 15-kibana.sh        # Kibana + Elastic Security
│   ├── 20-suricata.sh      # Suricata IDS + emerging-all.rules
│   ├── 25-zeek.sh          # Zeek protocol analysis (JSON + community-id)
│   ├── 30-filebeat.sh      # Log shipping → ES + Kibana dashboards
│   ├── 35-arkime.sh        # Full PCAP + session indexing
│   ├── 40-hayabusa.sh      # Windows EVTX analyser
│   ├── 45-yara.sh          # YARA + community rulesets
│   └── 50-kape.sh          # KAPE parser ecosystem
│
├── config/
│   ├── suricata/           # suricata.yaml overrides, threshold.config
│   ├── zeek/               # local.zeek, node.cfg
│   ├── elasticsearch/      # jvm.options overrides
│   ├── kibana/             # kibana.yml overrides
│   ├── filebeat/           # module configs
│   └── arkime/             # config.ini template
│
├── rules/
│   ├── update-et.sh        # Suricata emerging-all.rules updater
│   └── update-yara.sh      # YARA community rule puller
│
├── samples/                # Test PCAPs (gitignored, too large for repo)
│
├── tests/
│   └── smoke-test.sh       # Post-install health check
│
└── docs/
    └── (architecture docs, runbooks, team notes)
```

## Running individual modules

```bash
# Run a single module
sudo ./install.sh --module 20

# List available modules
sudo ./install.sh --list

# Preflight checks only (no changes)
sudo ./install.sh --check
```

Modules are idempotent — safe to re-run.

## Processing PCAPs

Drop `.pcap` files into `evidence/pcap/` and run:

```bash
sudo ./process-pcaps.sh
```

This runs both Suricata and Zeek against each PCAP and writes structured output to `evidence/processed/<name>/suricata/` and `evidence/processed/<name>/zeek/`.

```bash
# Process a single file
sudo ./process-pcaps.sh demo.pcap

# Re-process after rule updates
sudo ./process-pcaps.sh --reprocess
```

To import PCAPs into Arkime for session-level analysis:

```bash
sudo /opt/arkime/bin/capture --copy -r samples/demo.pcap -c /opt/arkime/etc/config.ini
```

## Version pinning

Tool versions are pinned in `versions.conf`. Update versions there and re-run the relevant module to upgrade. This keeps every team member's VM reproducible.

## Data flow

```
Network traffic / PCAP replay
    ├─→ Suricata (alerts + protocol logs → eve.json)
    │       └─→ Filebeat ──→ Elasticsearch ←── Kibana
    ├─→ Zeek (conn/protocol logs → JSON)
    │       └─→ Filebeat ──┘
    └─→ Arkime (full PCAP + session metadata → ES)
            └─→ Arkime Viewer (web UI)

Offline analysis:
    ├─ process-pcaps.sh  ← PCAPs in evidence/pcap/
    ├─ Hayabusa          ← EVTX files in evidence/evtx/
    ├─ YARA              ← samples in evidence/samples/
    └─ KAPE parsers      ← output in evidence/kape-output/
```

## Design decisions

- **HOME_NET / EXTERNAL_NET set to `any`** — this is a PCAP analysis workstation, not a perimeter sensor. Restricting HOME_NET causes rules to miss traffic from unknown source networks. A few ET rules using `!$HOME_NET` will fail to parse (expected, harmless).
- **Interface defaults to `lo`** — most work is offline PCAP analysis via `suricata -r`, `zeek -r`, and Arkime import. Team members doing live capture can set their physical interface during config.
- **`emerging-all.rules` instead of `suricata-update`** — the full ET Open ruleset with all categories enabled, downloaded directly. No rules silently disabled. Daily cron keeps it current.
- **ES security disabled** — lab environment. Don't run this config in production.

## After install

| Service | URL |
|---|---|
| Kibana | http://localhost:5601 |
| Arkime Viewer | http://localhost:8005 (admin / st0ne_buntu) |

```bash
# Suricata alerts
tail -f /var/log/suricata/fast.log

# Zeek logs
ls /opt/zeek/logs/current/

# Health check
sudo ./tests/smoke-test.sh
```

## Contributing

When adding a new module, follow the existing pattern: numbered prefix for ordering, header comment documenting purpose/dependencies/config, source `lib/common.sh` and the conf file, and make it idempotent.
