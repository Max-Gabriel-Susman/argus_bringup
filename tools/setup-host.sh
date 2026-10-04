#!/usr/bin/env bash
# setup-host.sh -- the host side of Argus Cybernetics from a clean Ubuntu
# 22.04 with ROS 2 Humble: clone the stack, install what it needs, fetch the
# training data, build and test the workspace, run the gateware benches.
# Rerunnable: every step skips what is already done.
#
#   git clone https://github.com/Max-Gabriel-Susman/argus_bringup ~/Documents/argus_ws/src/argus_bringup
#   bash ~/Documents/argus_ws/src/argus_bringup/tools/setup-host.sh
#
# Layout (the launch and the harness assume it; ARGUS_HOME moves the root):
#   $ARGUS_HOME/argus-neural-codec, argus_safety_controller, argus_data
#   $ARGUS_HOME/argus_ws/src/argus_core, argus_sensors, argus_inference, argus_sim, argus_bringup
#   ~/argus_data/            the datasets (never in git)
#
# What this does NOT do: Vivado/Vitis (gateware and firmware builds) and the
# board. See "From a clean machine" in the README for those.
set -euo pipefail

ARGUS_HOME=${ARGUS_HOME:-$HOME/Documents}
WS="$ARGUS_HOME/argus_ws"
GH=https://github.com/Max-Gabriel-Susman
SUDO=$(command -v sudo || true); [ "$(id -u)" = 0 ] && SUDO=""
ok()   { echo "ok     $*"; }
step() { echo; echo "==== $*"; }

step "1. system packages"
if ! command -v ros2 >/dev/null && [ ! -f /opt/ros/humble/setup.bash ]; then
  echo "FAIL   ROS 2 Humble is not installed. Follow https://docs.ros.org/en/humble/Installation/Ubuntu-Install-Debians.html, then rerun."
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq --no-install-recommends \
  git curl ca-certificates build-essential cmake python3-pip python3-venv \
  python3-colcon-common-extensions python3-rosdep python3-vcstool \
  ghdl shellcheck yamllint lsof tmux >/dev/null
ok "apt packages"

step "2. clone the stack"
mkdir -p "$ARGUS_HOME" "$WS/src"
for r in argus-neural-codec argus_safety_controller argus_data; do
  [ -d "$ARGUS_HOME/$r/.git" ] && ok "$r present" || { git clone -q "$GH/$r" "$ARGUS_HOME/$r" && ok "$r cloned"; }
done
for p in argus_core argus_sensors argus_inference argus_sim argus_bringup; do
  [ -d "$WS/src/$p/.git" ] && ok "$p present" || { git clone -q "$GH/$p" "$WS/src/$p" && ok "$p cloned"; }
done

step "3. python tools"
pip3 install -q --user "vsg==3.35.0" numpy scipy scikit-learn h5py pynwb >/dev/null 2>&1 && ok "pip: vsg, numpy, scipy, scikit-learn, h5py, pynwb"
export PATH="$HOME/.local/bin:$PATH"

step "4. ROS dependencies and the workspace"
set +u; source /opt/ros/humble/setup.bash; set -u
if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then $SUDO rosdep init >/dev/null 2>&1 || true; fi
rosdep update >/dev/null 2>&1 || true
( cd "$WS" && rosdep install --from-paths src --ignore-src -y -r >/dev/null 2>&1 ) && ok "rosdep" || echo "note   rosdep reported something; the build below is the real test"
( cd "$WS" && colcon build --packages-select argus_core argus_sensors argus_inference argus_sim argus_bringup > "$WS/setup-build.log" 2>&1 ) \
  && ok "colcon build (5 packages)" || { tail -30 "$WS/setup-build.log"; echo "FAIL   colcon build; log $WS/setup-build.log"; exit 1; }
( cd "$WS" && colcon test --packages-select argus_core argus_sensors argus_inference argus_sim > "$WS/setup-test.log" 2>&1; colcon test-result 2>/dev/null | tail -1 )

step "5. the datasets"
mkdir -p "$HOME/argus_data"
if [ -x "$ARGUS_HOME/argus_data/scripts/fetch.sh" ]; then
  bash "$ARGUS_HOME/argus_data/scripts/fetch.sh" && ok "training set fetched (the .mat; see argus_data for the broadband and the replay files)"
else echo "note   argus_data/scripts/fetch.sh missing; see that repo's README"; fi

step "6. the gateware benches (GHDL + VSG, no Xilinx tools needed)"
( cd "$ARGUS_HOME/argus-neural-codec" && vsg -c vsg.yaml -f rtl/*.vhd | grep -c "Total Violations:    0" ) | sed 's/^/       RTL files lint-clean: /'
( cd "$ARGUS_HOME/argus-neural-codec/sim" && make > "$ARGUS_HOME/argus-neural-codec/sim/setup-make.log" 2>&1 && grep -c "PASS" "$ARGUS_HOME/argus-neural-codec/sim/setup-make.log" ) | sed 's/^/       benches passed: /'

step "7. the launch parses"
set +u; source "$WS/install/setup.bash"; set -u
ros2 launch argus_bringup argus.launch.py --show-args | grep -c "^    '" | sed 's/^/       launch arguments: /'

echo
echo "host side ready. Next, for the board (see argus_bringup/README.md, 'From a clean machine'):"
echo "  1. Vivado + Vitis 2026.1:   argus-neural-codec: vivado -mode batch -source tools/build_bitstream.tcl argus_neural_codec.xpr"
echo "                              argus_safety_controller: tools/build_firmware.sh"
echo "  2. the replay files:        argus_data/scripts/derive.sh  (needs the 1 GB broadband NWB; see argus_data)"
echo "  3. the decoder model:       python3 $WS/src/argus_sim/tools/decode_test.py <374 s .bin> --save-model ~/argus_model.pkl"
echo "  4. the board on USB and 192.168.1.10, then:"
echo "       source /opt/ros/humble/setup.bash && source $WS/install/setup.bash"
echo "       ros2 launch argus_bringup argus.launch.py program:=true model:=\$HOME/argus_model.pkl"
