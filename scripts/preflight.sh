#!/usr/bin/env bash
# The checks that have cost the most time when skipped. Informational: it
# prints a verdict per check and the launch carries on regardless, so a
# missing console does not stop a host-only session.
set -uo pipefail

DATASET=${1:-}
MAT=${2:-}
DEV=${3:-/dev/ttyUSB1}
BOARD=${ARGUS_BOARD_IP:-192.168.1.10}
ADAPTER=${ARGUS_ADAPTER:-enx00e04c685e7e}

ok()   { echo "preflight  ok    $*"; }
warn() { echo "preflight  WARN  $*"; }

# Route to the board must leave by the board adapter, not a VPN tunnel.
route=$(ip route get "$BOARD" 2>/dev/null | head -1)
if [[ "$route" == *"dev $ADAPTER"* ]]; then
  ok "route to $BOARD via $ADAPTER"
elif [[ "$route" == *"nordlynx"* ]]; then
  warn "route to $BOARD goes via nordlynx -- disconnect the VPN"
else
  warn "route to $BOARD: ${route:-none}"
fi

if [ -n "$DATASET" ]; then
  if [ -f "$DATASET" ]; then
    ok "replay dataset $DATASET ($(du -h "$DATASET" | cut -f1))"
  else
    warn "replay dataset missing: $DATASET (relay will serve the synthetic pattern or fail)"
  fi
fi

if [ -n "$MAT" ]; then
  if [ -f "$MAT" ]; then
    ok "training set $MAT"
  else
    warn "training set missing: $MAT (decoder will exit)"
  fi
fi

if [ -c "$DEV" ]; then
  if command -v lsof >/dev/null && lsof "$DEV" >/dev/null 2>&1; then
    warn "$DEV is held by another process (a stale screen?): lsof $DEV"
  else
    ok "console $DEV free"
  fi
else
  warn "console $DEV not present"
fi

if command -v screen >/dev/null && screen -ls 2>/dev/null | grep -q tty; then
  warn "a screen session exists -- screen -ls; it may hold the console"
fi

exit 0
