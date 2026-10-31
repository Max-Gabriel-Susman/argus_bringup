#!/usr/bin/env bash
# hwtest.sh -- the hardware-in-the-loop cycle as one command with a verdict.
#
#   scripts/hwtest.sh                       # program the board, run 60 s, judge
#   scripts/hwtest.sh --firmware            # build firmware first (~2 min)
#   scripts/hwtest.sh --fabric --firmware   # build gateware too (~3 min more)
#   scripts/hwtest.sh --seconds 120 --no-decode
#   scripts/hwtest.sh --judge ~/Documents/hwtest-<stamp>.log   # re-judge a past log
#
# Builds refuse on their own failures (timing, compile). The run is
# `ros2 launch argus_bringup argus.launch.py program:=true` under a
# timeout, its log kept at ~/Documents/hwtest-<stamp>.log. The verdict is
# the lines that matter, and the exit status is PASS (0) or FAIL (1):
#
#   PASS needs: acq id 41435133 with no EXPECTED, tx lines advancing,
#               frames ok= on the host, and no "hold never took effect".
#   Printed:    the last two stream: lines and the last feat: line, so a
#               throughput or feature regression is visible even on PASS.
#
# Which firmware, and a bring-up ladder (for the Rust port):
#
#   scripts/hwtest.sh --repo ~/Documents/argus_safety_controller_rusty --stage boot
#   scripts/hwtest.sh --repo <checkout> --firmware --stage replay
#   scripts/hwtest.sh --judge <log> --stage telemetry
#
# --repo is the firmware checkout whose tools/program.sh programs the board
# (default ~/Documents/argus_safety_controller). With --firmware, a checkout
# that has rust/tools/build-fw.sh is built with it, otherwise with
# tools/build_firmware.sh. Without --stage the verdict is the one above.
# --stage judges a ladder instead, each stage including the ones before it:
#
#   boot       a boot banner (the C firmware's "Initializing Argus Safety
#              Controller" or the Rust firmware's "argus-fw <rev> boot"),
#              three console lines after it, and no "panic:" or "fault:"
#   acq        acq id= without EXPECTED, a feat: line, no "hold never took effect"
#   net        the board answers at least 8 of 10 pings during the run
#   telemetry  tx lines advancing, frames ok= climbing on the host, and none
#              of the host's reject counters (size, magic, ver, crc) rising
#              after the banner
#   replay     replay ok:, then across the last two stream: reports at least
#              1015 more halves, underruns=0, and rtx=0 to=0 rej=0
#   bitexact   hw_bitexact.py compare exact on 1450 bins (runs at least 110 s)
#
# One board: a run holds ~/Documents/.argus-board.lock while it programs and
# runs, so two runs never overlap. A second run waits up to 15 minutes
# (ARGUS_BOARD_WAIT seconds), then exits 3, BOARD BUSY. A caller holding the
# lock for a longer session sets ARGUS_BOARD_LOCK_HELD=1. A run started by an
# automated job (ARGUS_LOOP set) exits 3, BOARD ON HOLD, while
# ~/Documents/.argus-board-hold exists.
#
# Exit status: 0 PASS, 1 FAIL, 2 usage, 3 board busy or on hold, 4 not ready
# (stale ROS processes, the UDP ports taken, the VPN route, the console
# missing or held, or taken by another reader during the run). On 3 and 4
# nothing was judged.
#
# pipefail is on, so no check below pipes into a reader that stops early
# (head -1, grep -q, grep -m1): on a long log the writer dies of SIGPIPE and
# the check fails although it matched. Checks count matches, or read one
# line with sed, instead.
#
# The only hardware-touching command an automated job may run.
set -uo pipefail

DOCS="$HOME/Documents"
CODEC="$DOCS/argus-neural-codec"
FW="$DOCS/argus_safety_controller"
WS="$DOCS/argus_ws"
SECONDS_RUN=60
FABRIC=0; FIRMWARE=0; DECODE=true; JUDGE=""; STAGE=""
CONSOLE_DEV=/dev/ttyUSB1
BITEXACT_BIN="$HOME/argus_data/indy_20161005_06_s120_10s.bin"
BITEXACT_BINS=1450
MIN_HALVES=${ARGUS_MIN_HALVES:-1015}

while [ $# -gt 0 ]; do
  case "$1" in
    --fabric) FABRIC=1 ;;
    --firmware) FIRMWARE=1 ;;
    --no-decode) DECODE=false ;;
    --seconds) shift; SECONDS_RUN=$1 ;;
    --judge) shift; JUDGE=$1 ;;
    --repo) shift; FW=${1%/} ;;
    --stage) shift; STAGE=$1 ;;
    --console-dev) shift; CONSOLE_DEV=$1 ;;
    --bitexact-bin) shift; BITEXACT_BIN=$1 ;;
    *) echo "hwtest: unknown option $1"; exit 2 ;;
  esac
  shift
done

STAGES="boot acq net telemetry replay bitexact"
stage_rank() { local i=0 s; for s in $STAGES; do i=$((i+1)); [ "$s" = "$1" ] && { echo "$i"; return; }; done; echo 0; }
if [ -n "$STAGE" ] && [ "$(stage_rank "$STAGE")" -eq 0 ]; then
  echo "hwtest: unknown stage $STAGE (one of: $STAGES)"; exit 2
fi
# True when the requested stage includes stage $1.
at_least() { [ -n "$STAGE" ] && [ "$(stage_rank "$STAGE")" -ge "$(stage_rank "$1")" ]; }
if at_least bitexact && [ "$SECONDS_RUN" -lt 110 ]; then SECONDS_RUN=110; fi

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$DOCS/hwtest-$STAMP.log"
fail() { echo "hwtest: FAIL  $*"; echo "hwtest: log $LOG"; exit 1; }

if [ -n "$JUDGE" ]; then
  LOG=$JUDGE
  [ -f "$LOG" ] || fail "no such log $LOG"
else

# --- one board --------------------------------------------------------------
HOLD_FILE="$DOCS/.argus-board-hold"
LOCK_FILE="$DOCS/.argus-board.lock"
if [ -n "${ARGUS_LOOP:-}" ] && [ -e "$HOLD_FILE" ]; then
  echo "hwtest: BOARD ON HOLD: $(head -1 "$HOLD_FILE" 2>/dev/null)"
  exit 3
fi
if [ "${ARGUS_BOARD_LOCK_HELD:-0}" != 1 ] && command -v flock >/dev/null; then
  exec 9>"$LOCK_FILE"
  if ! flock -w "${ARGUS_BOARD_WAIT:-900}" 9; then
    echo "hwtest: BOARD BUSY: $(cat "$LOCK_FILE.owner" 2>/dev/null)"
    exit 3
  fi
  echo "$(date '+%F %T') pid $$ ${ARGUS_LOOP:-by hand} $FW" > "$LOCK_FILE.owner"
fi

# --- preconditions: the ones that have cost the most time ------------------
# These say the machine or the board is not ready, not that the firmware is
# wrong, so they exit 4 and nothing is programmed. A loop waits and retries.
notready() { echo "hwtest: FAIL  $* (not ready; nothing was run)"; exit 4; }

# A ROS node left from an earlier run shares the stack's UDP ports and
# topics. Matched by executable name (the kernel keeps the first 15
# characters), so shells, editors and other tools that merely mention these
# names on their command lines never count. A node in another ROS domain
# cannot reach this graph and is left alone; if it holds 5005 or 5010, the
# port check below still stops the run.
our_domain=${ROS_DOMAIN_ID:-0}
stale=""
for pid in $(pgrep -x 'dataset_relay_n|neural_udp_rece|neural_telemetr|inference_node|ros2' 2>/dev/null); do
  state=$(sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "/proc/$pid/status" 2>/dev/null)
  [ -z "$state" ] || [ "$state" = Z ] && continue    # gone, or a zombie holding nothing
  cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") || continue
  if [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = ros2 ] && [[ "$cmd" != *" launch "* ]]; then
    continue   # ros2 topic echo and friends hold no ports
  fi
  dom=$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" | sed -n 's/^ROS_DOMAIN_ID=//p' | head -1)
  [ "${dom:-0}" != "$our_domain" ] && continue
  stale+="$pid $cmd"$'\n'
done
if [ -n "$stale" ]; then
  printf '%s' "$stale" | cut -c1-120 | sed 's/^/hwtest:   stale: /'
  notready "ROS processes from a previous run are alive (they share the UDP ports); pkill -INT -f 'dataset_relay_node|neural_udp_receiver|neural_telemetry_receiver_node|inference_node'"
fi
# Anything else on the stack's ports (a test server, a stray relay) steals
# the board's datagrams just as surely. /proc lists every bound UDP socket,
# ports in hex: 138D is 5005, 1392 is 5010.
ports=$(awk 'FNR > 1 { split($2, a, ":"); p = toupper(a[2]);
                       if (p == "138D") print 5005; if (p == "1392") print 5010 }' \
        /proc/net/udp /proc/net/udp6 2>/dev/null | sort -u | tr '\n' ' ')
[ -n "$ports" ] && notready "UDP ${ports}already bound on this machine; find the owner with: ss -lunp | grep -E ':(5005|5010)'"
route=$(ip route get 192.168.1.10 2>/dev/null | head -1)
[[ "$route" == *"nordlynx"* ]] && notready "route to the board goes via the VPN; disconnect it"
[ -c "$CONSOLE_DEV" ] || notready "no $CONSOLE_DEV -- board USB not connected or powered"
if command -v lsof >/dev/null && lsof "$CONSOLE_DEV" >/dev/null 2>&1; then
  notready "$CONSOLE_DEV is held by another process (screen?)"
fi
[ -f "$FW/tools/program.sh" ] || fail "no $FW/tools/program.sh (wrong --repo?)"

# --- builds ---------------------------------------------------------------
if [ "$FABRIC" -eq 1 ]; then
  echo "hwtest: building gateware"
  ( cd "$CODEC" && set +u && . "${XILINX_VIVADO:-/tools/Xilinx/2026.1/Vivado}/settings64.sh" && set -u &&
    vivado -mode batch -nolog -nojournal -source tools/build_bitstream.tcl argus_neural_codec.xpr ) \
    > "$DOCS/hwtest-$STAMP-vivado.log" 2>&1 9>&- \
    || fail "gateware build failed (timing or synthesis); see $DOCS/hwtest-$STAMP-vivado.log"
  grep -E "=== implemented|exported" "$DOCS/hwtest-$STAMP-vivado.log" | sed 's/^/hwtest: /'
fi
if [ "$FIRMWARE" -eq 1 ]; then
  if [ -f "$FW/rust/tools/build-fw.sh" ]; then
    echo "hwtest: building firmware (rust/tools/build-fw.sh)"
    bash "$FW/rust/tools/build-fw.sh" > "$DOCS/hwtest-$STAMP-build.log" 2>&1 9>&- \
      || fail "firmware build failed; see $DOCS/hwtest-$STAMP-build.log"
    tail -1 "$DOCS/hwtest-$STAMP-build.log" | sed 's/^/hwtest: /'
  else
    echo "hwtest: building firmware"
    "$FW/tools/build_firmware.sh" > "$DOCS/hwtest-$STAMP-vitis.log" 2>&1 9>&- \
      || fail "firmware build failed; see $DOCS/hwtest-$STAMP-vitis.log"
    tail -1 "$DOCS/hwtest-$STAMP-vitis.log" | sed 's/^/hwtest: /'
  fi
fi

# --- run ------------------------------------------------------------------
set +u
. /opt/ros/humble/setup.bash
. "$WS/install/setup.bash"
set -u

# Stage helpers that run beside the launch. Their results sit next to the
# log, so --judge can read them again later.
if at_least net; then
  ( sleep "${ARGUS_PING_AFTER:-30}"; ping -c 10 -i 0.5 -W 1 192.168.1.10 ) > "$LOG.ping" 2>&1 9>&- &
  ping_pid=$!
fi
if at_least bitexact; then
  CAPTURE="$DOCS/hwtest-$STAMP-capture.npz"
  python3 "$WS/src/argus_sim/tools/hw_bitexact.py" capture "$CAPTURE" \
    --seconds $((SECONDS_RUN + 20)) > "$LOG.capture" 2>&1 9>&- &
  capture_pid=$!
  sleep 3   # listening before the board starts sending
fi

echo "hwtest: programming $FW and running for ${SECONDS_RUN}s"
timeout --signal=INT --kill-after=15 "$SECONDS_RUN" \
  ros2 launch argus_bringup argus.launch.py program:=true decode:="$DECODE" \
  firmware:="$FW" console_dev:="$CONSOLE_DEV" > "$LOG" 2>&1 9>&-
rc=$?
# 124 is the timeout we asked for; anything else that early is a launch failure.
if [ "$rc" -ne 124 ] && [ "$rc" -ne 0 ]; then
  tail -30 "$LOG" | sed 's/^/  /'; fail "launch exited $rc before the timeout"
fi

if at_least net; then wait "$ping_pid" 2>/dev/null; fi
if at_least bitexact; then
  wait "$capture_pid" 2>/dev/null
  echo "hwtest: comparing against the model (hw_bitexact.py, ${BITEXACT_BINS} bins)"
  python3 "$WS/src/argus_sim/tools/hw_bitexact.py" compare "$BITEXACT_BIN" "$CAPTURE" \
    --bins "$BITEXACT_BINS" > "$LOG.bitexact" 2>&1 9>&-
  echo "hwtest-bitexact-rc=$?" >> "$LOG.bitexact"
fi

# console.sh holds the port exclusively; if something else opened it between
# the check above and the launch, the launch's console got "busy" and the run
# has no console to judge.
if grep -aq 'console: .* is busy' "$LOG"; then
  echo "hwtest: FAIL  another reader took $CONSOLE_DEV before the launch's console did (not ready; nothing was judged)"
  echo "hwtest: log $LOG"
  exit 4
fi

fi  # not --judge

# --- verdict --------------------------------------------------------------
if [ -z "$STAGE" ]; then
# Only what happened after this run's own banner counts: the board keeps
# printing its previous firmware's lines until program-7 reprograms it, and
# the receiver keeps counting that firmware's frames. Everything before the
# last "acq id=" is another run's evidence.
banner_ln=$(grep -an 'acq id=' "$LOG" | tail -1 | cut -d: -f1 || true)
else
# The ladder anchors on the boot banner instead, since the early stages
# come before the firmware reads the fabric ID.
banner_ln=$(grep -anE 'Initializing Argus Safety Controller|argus-fw .* boot' "$LOG" | tail -1 | cut -d: -f1 || true)
[ -z "$banner_ln" ] && banner_ln=$(grep -an 'acq id=' "$LOG" | tail -1 | cut -d: -f1 || true)
fi
if [ -n "$banner_ln" ]; then post() { tail -n +"$banner_ln" "$LOG"; }; else post() { cat "$LOG"; }; fi
con() { post | grep -a '^\[console-' | sed 's/^\[console-[0-9]*\] //'; }
id_line=$(con | grep -m1 'acq id=' || true)
tx_first=$(con | grep -m1 '^tx ' || true)
tx_last=$(con | grep '^tx ' | tail -1 || true)
frames_first=$(post | grep -a -m1 'frames ok=' || true)
frames=$(post | grep -a 'frames ok=' | tail -1 || true)
hold=$(con | grep -m1 'hold never took effect' || true)
stream=$(con | grep '^stream:' | tail -3 || true)
feat=$(con | grep '^feat:' | tail -1 || true)
intent=$(post | grep -a 'intent=' | tail -1 | sed 's/.*\[argus_inference\]: //' || true)
program_err=$(grep -a -m1 -E 'no JTAG targets|program\.(tcl|sh): missing|Failed to download' "$LOG" || true)
fnum() { echo "$1" | grep -o 'frames ok=[0-9]*' | grep -o '[0-9]*$'; }
# One counter from a receiver report: field_of "<line>" crc
field_of() { printf '%s\n' "$1" | grep -oE "(^| )$2=[0-9]+" | tail -1 | grep -oE '[0-9]+$' || true; }
# Matches, counted: reads all its input, so pipefail cannot misfire on it.
count() { grep -ac -- "$1" || true; }
banner_re='Initializing Argus Safety Controller|argus-fw .* boot'

echo "hwtest: ---- verdict ($LOG) ----"
[ -n "$STAGE" ]     && echo "hwtest:   stage $STAGE, firmware $(grep -aoE 'argus-fw [^ ]+' "$LOG" | tail -1 || true)"
[ -n "$id_line" ]   && echo "hwtest:   $id_line"   || echo "hwtest:   (no acq id line)"
[ -n "$tx_first" ]  && echo "hwtest:   $tx_first"
[ -n "$tx_last" ]   && echo "hwtest:   $tx_last"
[ -n "$frames" ]    && echo "hwtest:   host: ${frames##*]: }"
[ -n "$stream" ]    && echo "$stream" | sed 's/^/hwtest:   /'
[ -n "$feat" ]      && echo "hwtest:   $feat"
[ -n "$intent" ]    && echo "hwtest:   decoder: $intent"
[ -n "$program_err" ] && echo "hwtest:   $program_err"

status=0
[ -n "$program_err" ]                          && { echo "hwtest:   programming failed"; status=1; }

frames_check() {
  frames_n=$(post | grep -ac 'frames ok=' || true)
  if [ "${frames_n:-0}" -lt 2 ]; then
    echo "hwtest:   fewer than two host stats lines after the banner (run too short?)"; status=1
  elif [ "$(fnum "$frames")" -le "$(fnum "$frames_first")" ]; then
    echo "hwtest:   host frame count did not climb after the banner ($(fnum "$frames_first") -> $(fnum "$frames"))"; status=1
  fi
}

if [ -z "$STAGE" ]; then
  [ -z "$id_line" ]                              && { echo "hwtest:   board never printed its banner"; status=1; }
  [[ "$id_line" == *EXPECTED* ]]                 && { echo "hwtest:   fabric/firmware revision mismatch"; status=1; }
  [ -n "$hold" ]                                 && { echo "hwtest:   $hold"; status=1; }
  [ -z "$tx_last" ] || [ "$tx_first" = "$tx_last" ] && { echo "hwtest:   no advancing tx lines"; status=1; }
  frames_check
else
  # boot
  banner_line=""
  [ -n "$banner_ln" ] && banner_line=$(sed -n "${banner_ln}p" "$LOG")
  if ! [[ "$banner_line" =~ $banner_re ]]; then
    echo "hwtest:   no boot banner"; status=1
  fi
  after=$(con | wc -l)
  [ "$after" -lt 4 ] && { echo "hwtest:   only $after console lines from the banner on"; status=1; }
  crash=$(con | grep -m1 -E '^(panic|fault):' || true)
  [ -n "$crash" ] && { echo "hwtest:   $crash"; status=1; }
  if at_least acq; then
    [ -z "$id_line" ]              && { echo "hwtest:   no acq id line"; status=1; }
    [[ "$id_line" == *EXPECTED* ]] && { echo "hwtest:   fabric/firmware revision mismatch"; status=1; }
    [ -z "$feat" ]                 && { echo "hwtest:   no feat: line"; status=1; }
    [ -n "$hold" ]                 && { echo "hwtest:   $hold"; status=1; }
  fi
  if at_least net; then
    got=$(grep -oE '[0-9]+ received' "$LOG.ping" 2>/dev/null | grep -oE '^[0-9]+' || true)
    echo "hwtest:   ping: ${got:-no result} of 10 replies"
    [ "${got:-0}" -lt 8 ] && { echo "hwtest:   the board did not answer pings"; status=1; }
  fi
  if at_least telemetry; then
    [ -z "$tx_last" ] || [ "$tx_first" = "$tx_last" ] && { echo "hwtest:   no advancing tx lines"; status=1; }
    frames_check
    # Every frame the host turned away is a firmware fault: a bad CRC or a
    # malformed packet. The receiver's counters run from its own start, which
    # is before programming, so they are counted from its last report at or
    # before the banner: frames the previous image sent are not this one's.
    pre=""
    [ -n "$banner_ln" ] && pre=$(head -n "$banner_ln" "$LOG" | grep -a 'frames ok=' | tail -1 || true)
    for field in size magic ver crc; do
      n1=$(field_of "$frames" "$field")
      [ -z "$n1" ] && continue
      n0=$(field_of "$pre" "$field")
      d=$((n1 - ${n0:-0}))
      [ "$d" -ne 0 ] && { echo "hwtest:   host counted $field=$d after the banner"; status=1; }
    done
  fi
  if at_least replay; then
    [ "$(con | count '^replay ok:')" -gt 0 ] || { echo "hwtest:   no 'replay ok:' line"; status=1; }
    halves=$(con | grep -a '^stream: halves=' | tail -2 | grep -oE 'halves=[0-9]+' | grep -oE '[0-9]+' || true)
    if [ "$(echo "$halves" | grep -c .)" -lt 2 ]; then
      echo "hwtest:   fewer than two stream: halves= reports"; status=1
    else
      h0=$(echo "$halves" | head -1); h1=$(echo "$halves" | tail -1)
      echo "hwtest:   halves per report: $((h1 - h0)) (need $MIN_HALVES)"
      [ $((h1 - h0)) -lt "$MIN_HALVES" ] && { echo "hwtest:   replay below real time"; status=1; }
    fi
    under=$(con | grep -a '^stream: halves=' | tail -1 | grep -oE 'underruns=[0-9]+' || true)
    [ "$under" != "underruns=0" ] && { echo "hwtest:   ${under:-no underruns field}"; status=1; }
    errs=$(con | grep -a '^stream: fetch' | tail -1 | grep -oE 'rtx=[0-9]+ to=[0-9]+ rej=[0-9]+' || true)
    [ "$errs" != "rtx=0 to=0 rej=0" ] && { echo "hwtest:   replay errors: ${errs:-no counters line}"; status=1; }
  fi
  if at_least bitexact; then
    grep -aE '^ *bins exact|WARNING' "$LOG.bitexact" 2>/dev/null | sed -n '1,4s/^ */hwtest:   /p'
    grep -qx 'hwtest-bitexact-rc=0' "$LOG.bitexact" 2>/dev/null \
      || { echo "hwtest:   not bit-exact (see $LOG.bitexact)"; status=1; }
  fi
fi

if [ "$status" -eq 0 ]; then echo "hwtest: PASS"; else echo "hwtest: FAIL"; fi
exit "$status"
