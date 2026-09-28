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
# The only hardware-touching command an unattended loop may run.
set -uo pipefail

DOCS="$HOME/Documents"
CODEC="$DOCS/argus-neural-codec"
FW="$DOCS/argus_safety_controller"
WS="$DOCS/argus_ws"
SECONDS_RUN=60
FABRIC=0; FIRMWARE=0; DECODE=true; JUDGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --fabric) FABRIC=1 ;;
    --firmware) FIRMWARE=1 ;;
    --no-decode) DECODE=false ;;
    --seconds) shift; SECONDS_RUN=$1 ;;
    --judge) shift; JUDGE=$1 ;;
    *) echo "hwtest: unknown option $1"; exit 2 ;;
  esac
  shift
done

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$DOCS/hwtest-$STAMP.log"
fail() { echo "hwtest: FAIL  $*"; echo "hwtest: log $LOG"; exit 1; }

if [ -n "$JUDGE" ]; then
  LOG=$JUDGE
  [ -f "$LOG" ] || fail "no such log $LOG"
else

# --- preconditions: the ones that have cost the most time ------------------
# The autopilot's own claude process mentions these names on its command
# line (the allowed-tools list); it is not a ROS process.
stale=$(pgrep -af "dataset_relay_node|neural_udp_receiver|neural_telemetry_receiver_node|inference_node|ros2 launch" 2>/dev/null | grep -vE "hwtest|claude -p|autopilot" || true)
if [ -n "$stale" ]; then
  echo "$stale" | cut -c1-120 | sed 's/^/hwtest:   stale: /'
  fail "ROS processes from a previous run are alive (they share the UDP ports); pkill -INT -f 'dataset_relay_node|neural_udp_receiver|neural_telemetry_receiver_node|inference_node'"
fi
route=$(ip route get 192.168.1.10 2>/dev/null | head -1)
[[ "$route" == *"nordlynx"* ]] && fail "route to the board goes via the VPN; disconnect it"
[ -c /dev/ttyUSB1 ] || fail "no /dev/ttyUSB1 -- board USB not connected or powered"
if command -v lsof >/dev/null && lsof /dev/ttyUSB1 >/dev/null 2>&1; then
  fail "/dev/ttyUSB1 is held by another process (screen?)"
fi

# --- builds ---------------------------------------------------------------
if [ "$FABRIC" -eq 1 ]; then
  echo "hwtest: building gateware"
  ( cd "$CODEC" && set +u && . /tools/Xilinx/2026.1/Vivado/settings64.sh && set -u &&
    vivado -mode batch -nolog -nojournal -source tools/build_bitstream.tcl argus_neural_codec.xpr ) \
    > "$DOCS/hwtest-$STAMP-vivado.log" 2>&1 \
    || fail "gateware build failed (timing or synthesis); see $DOCS/hwtest-$STAMP-vivado.log"
  grep -E "=== implemented|exported" "$DOCS/hwtest-$STAMP-vivado.log" | sed 's/^/hwtest: /'
fi
if [ "$FIRMWARE" -eq 1 ]; then
  echo "hwtest: building firmware"
  "$FW/tools/build_firmware.sh" > "$DOCS/hwtest-$STAMP-vitis.log" 2>&1 \
    || fail "firmware build failed; see $DOCS/hwtest-$STAMP-vitis.log"
  tail -1 "$DOCS/hwtest-$STAMP-vitis.log" | sed 's/^/hwtest: /'
fi

# --- run ------------------------------------------------------------------
set +u
. /opt/ros/humble/setup.bash
. "$WS/install/setup.bash"
set -u
echo "hwtest: programming and running for ${SECONDS_RUN}s"
timeout --signal=INT --kill-after=15 "$SECONDS_RUN" \
  ros2 launch argus_bringup argus.launch.py program:=true decode:="$DECODE" > "$LOG" 2>&1
rc=$?
# 124 is the timeout we asked for; anything else that early is a launch failure.
if [ "$rc" -ne 124 ] && [ "$rc" -ne 0 ]; then
  tail -30 "$LOG" | sed 's/^/  /'; fail "launch exited $rc before the timeout"
fi

fi  # not --judge

# --- verdict --------------------------------------------------------------
# Only what happened after this run's own banner counts: the board keeps
# printing its previous firmware's lines until program-7 reprograms it, and
# the receiver keeps counting that firmware's frames. Everything before the
# last "acq id=" is another run's evidence.
banner_ln=$(grep -an 'acq id=' "$LOG" | tail -1 | cut -d: -f1 || true)
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
program_err=$(grep -a -m1 -E 'no JTAG targets|program.tcl: missing|Failed to download' "$LOG" || true)
fnum() { echo "$1" | grep -o 'frames ok=[0-9]*' | grep -o '[0-9]*$'; }

echo "hwtest: ---- verdict ($LOG) ----"
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
[ -z "$id_line" ]                              && { echo "hwtest:   board never printed its banner"; status=1; }
[[ "$id_line" == *EXPECTED* ]]                 && { echo "hwtest:   fabric/firmware revision mismatch"; status=1; }
[ -n "$hold" ]                                 && { echo "hwtest:   $hold"; status=1; }
[ -z "$tx_last" ] || [ "$tx_first" = "$tx_last" ] && { echo "hwtest:   no advancing tx lines"; status=1; }
frames_n=$(post | grep -ac 'frames ok=' || true)
if [ "${frames_n:-0}" -lt 2 ]; then
  echo "hwtest:   fewer than two host stats lines after the banner (run too short?)"; status=1
elif [ "$(fnum "$frames")" -le "$(fnum "$frames_first")" ]; then
  echo "hwtest:   host frame count did not climb after the banner ($(fnum "$frames_first") -> $(fnum "$frames"))"; status=1
fi

if [ "$status" -eq 0 ]; then echo "hwtest: PASS"; else echo "hwtest: FAIL"; fi
exit "$status"
