# st0ne_buntu

A modular toolkit for building a standardised Ubuntu 22.04 LTS forensics and network security monitoring workstation. Clone the repo on a fresh install, run the installer, and get a fully configured stack.

## What you get

| Tool | Purpose | Module |
|---|---|---|
| **Elasticsearch** | Shared indexing backend for all log/session data | `10-elasticsearch` |
| **Kibana** | Dashboards, Elastic Security SIEM, alert triage | `15-kibana` |
| **Suricata** | Signature-based IDS with ET Open rules (daily updates) | `20-suricata` |
| **Zeek** | Protocol analysis, connection logging, behavioural detection | `25-zeek` |
| **Filebeat** | Ships Suricata + Zeek logs into Elasticsearch | `30-filebeat` |
| **Arkime** | Full packet capture with indexed session search | `35-arkime` |
| **Hayabusa** | Fast Windows EVTX analysis with Sigma rules | `40-hayabusa` |
| **YARA** | File/malware pattern matching with community rulesets | `45-yara` |
| **KAPE parsers** | Windows forensic artifact parsers (Linux-side) | `50-kape` |

## Quick start

```bash
git clone https://github.com/yourorg/st0ne_buntu.git
cd st0ne_buntu
sudo ./install.sh
```

On first run you'll be prompted for your network interface, HOME_NET, and storage preferences. These are saved to `st0ne_buntu.conf` (gitignored — each team member gets their own).

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
├── st0ne_buntu.conf        # Local config (generated, gitignored)
├── versions.conf           # Pinned tool versions
├── .gitignore
│
├── lib/
│   ├── common.sh           # Shared functions, colours, helpers
│   ├── preflight.sh        # Pre-install validation
│   └── configure.sh        # First-run config generator
│
├── modules/
│   ├── 00-base.sh          # System deps, sysctl tuning, directories
│   ├── 10-elasticsearch.sh # Single-node ES, heap tuning, ILM
│   ├── 15-kibana.sh        # Kibana + Elastic Security
│   ├── 20-suricata.sh      # Suricata IDS + ET Open + daily cron
│   ├── 25-zeek.sh          # Zeek protocol analysis
│   ├── 30-filebeat.sh      # Log shipping → ES
│   ├── 35-arkime.sh        # Full PCAP + session indexing
│   ├── 40-hayabusa.sh      # Windows EVTX analyser
│   ├── 45-yara.sh          # YARA + community rulesets
│   └── 50-kape.sh          # KAPE parser ecosystem
│
├── config/
│   ├── suricata/           # suricata.yaml overrides, threshold, disable.conf
│   ├── zeek/               # local.zeek, node.cfg
│   ├── elasticsearch/      # jvm.options overrides, ILM policy JSON
│   ├── kibana/             # kibana.yml overrides, saved objects
│   ├── filebeat/           # module configs
│   └── arkime/             # config.ini template
│
├── rules/
│   ├── update-et.sh        # Suricata rule update wrapper
│   └── update-yara.sh      # YARA community rule puller
│
├── tests/
│   └── smoke-test.sh       # Post-install health check
│
├── evidence/               # Standard evidence directory layout
│   ├── pcap/               # Arkime PCAP storage
│   ├── evtx/               # Windows event logs for Hayabusa
│   ├── yara-hits/          # YARA scan output
│   ├── kape-output/        # KAPE triage output
│   └── samples/            # Malware/file samples
│
└── docs/
    └── (architecture docs, runbooks, team notes)
```

## Running individual modules

Each module is independently runnable:

```bash
# Run just the Suricata module
sudo ./install.sh --module 20

# Or directly
sudo bash modules/20-suricata.sh st0ne_buntu.conf .
```

Modules are idempotent — safe to re-run.

## Version pinning

Tool versions are pinned in `versions.conf`. Update versions there and re-run the relevant module to upgrade. This keeps every team member's VM reproducible.

## Data flow

```
Network traffic
    ├─→ Suricata (alerts + protocol logs → eve.json)
    │       └─→ Filebeat ──→ Elasticsearch ←── Kibana
    ├─→ Zeek (conn/protocol logs → JSON)
    │       └─→ Filebeat ──┘
    └─→ Arkime (full PCAP + session metadata → ES)
            └─→ Arkime Viewer (web UI)

Offline analysis:
    ├─ Hayabusa ← EVTX files dropped in evidence/evtx/
    ├─ YARA     ← samples dropped in evidence/samples/
    └─ KAPE     ← output dropped in evidence/kape-output/
```

## After install

- **Kibana:** http://localhost:5601
- **Arkime Viewer:** http://localhost:8005
- **Suricata alerts:** `tail -f /var/log/suricata/fast.log`
- **Zeek logs:** `/opt/zeek/logs/current/`
- **Smoke test:** `sudo ./tests/smoke-test.sh`

## Contributing

When adding a new module, follow the existing pattern: numbered prefix for ordering, header comment documenting purpose/dependencies/config, source `lib/common.sh` and the conf file, and make it idempotent.
