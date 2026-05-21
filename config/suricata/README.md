# =============================================================================
# config/suricata/README.md
#
# This directory holds Suricata configuration overrides applied by module
# 20-suricata.sh on top of the default suricata.yaml.
#
# Files:
#   custom.yaml     — YAML overrides merged into suricata.yaml
#   threshold.config — Local threshold/suppression rules
#   disable.conf    — SIDs to disable (passed to suricata-update)
#   enable.conf     — SIDs to force-enable
#   modify.conf     — SID action modifications (alert→drop, etc.)
#
# The module backs up the original suricata.yaml before patching.
# To reset: sudo cp /etc/suricata/suricata.yaml.st0ne_buntu.orig /etc/suricata/suricata.yaml
# =============================================================================
