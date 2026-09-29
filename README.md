# Argus Cybernetics

Argus Cybernetics is a neural-acquisition and decoding pipeline built end to
end on real silicon: recorded macaque motor cortex is replayed into simulated
Intan RHD2132 amplifiers in the fabric of a Zynq-7000 (Arty Z7), a VHDL codec
in the same fabric extracts threshold crossings and spike-band power per
channel per 50 ms bin, the Cortex-A9 firmware ships them over UDP, and a
ROS 2 graph receives them, decodes reach intent with an LDA classifier and
drives `/cmd_vel`. The broadband comes from session `indy_20161005_06`
(O'Doherty, Cardoso, Makin & Sabes, CC-BY-4.0); where every file comes from is
in [argus_data](https://github.com/Max-Gabriel-Susman/argus_data). The loop
runs on hardware as of fabric revision ACQ3, with the replay path that
refills the fabric's BRAM from the host at real time.

**Data path.**
`~/argus_data/*.bin` → `dataset_relay_node` (UDP :5010) → PS refills replay
BRAM → 96 simulated RHD2132 chips → `argus_feature` (250 Hz high-pass,
3.5σ crossings, spike-band power, 50 ms bins) → AXI feature bank at `0x400`
→ firmware → UDP :5005, wire frame v3 → `neural_udp_receiver` →
`/argus/neural_interface_bridge/neural_data` → `neural_telemetry_receiver_node`
→ `/argus/sensors/neural_telemetry` → `inference_node` (StandardScaler → LDA)
→ `/cmd_vel`.

| Result | Value | Evidence |
| --- | --- | --- |
| Codec vs fixed-point model | bit-exact, 5760 (bin, channel) pairs | `argus-neural-codec` `sim/tb_argus_feature.vhd` against `sim/data/` |
| Decode, counts + power at 3.5σ | 53.5 % vs 49.9 % for the lab's sorted units (5-fold CV, 4 classes) | `argus_sim/tools/decode_test.py` |
| Timing closure | post-route WNS 0.924 ns at 125 MHz | `argus-neural-codec/tools/build_bitstream.tcl` |
| End to end | 20.007 Hz on `/cmd_vel` | `ros2 topic hz /cmd_vel` on the running stack |
| Replay throughput | real time: 203 halves/s (of 204), 2.4 ms fetch per 4.9 ms half, zero loss (rtx/to/rej 0, underruns 0 over 90 s) | `stream:` lines in `scripts/hwtest.sh` logs |
| Validated decoder live | `model:=` loaded; intents 0/1/2/3 = 17/4/37/15 of 73 logged frames (every 20th) over 72.7 s, `crc=0` | `hwtest-20260928-195120.log` |
| Codec on silicon vs model | bit-exact, 1450 bins × 96 ch (first 100 bins: 100 %) | `argus_sim/tools/hw_bitexact.py` during `hwtest.sh --seconds 90` |

## argus_bringup

One command for the Argus stack.

```bash
rosenv
ros2 launch argus_bringup argus.launch.py program:=true model:=$HOME/argus_model.pkl  # the demo
ros2 launch argus_bringup argus.launch.py                # host side only: relay, receiver, bridge, decoder, console
```

The demo passes `model:=` because that is the validated decoder: counts plus
spike-band power at 3.5σ, 53.5 % in 5-fold CV, the one the results table
reports. Without it the decoder trains on the `.mat` at startup on counts
only (44.0 %). Make the file once with `argus_sim/tools/decode_test.py ...
--mult 3.5 --features both --save-model ~/argus_model.pkl` (the full command
is in the argus_sim README). On the board it loads and decodes the fabric's
features: all four intents occur over a 90 s run (log `hwtest-20260928-195120.log`).

Build it from `~/Documents/argus_ws` with `colcon build --packages-select
argus_bringup`, and check it with `ros2 launch argus_bringup argus.launch.py
--show-args`.

It replaces the four terminals in `argus_safety_controller/RUNBOOK.md` and,
with `program:=true`, the Vitis **Run** button. Vitis is still where the
firmware and platform get *built*.

## What it starts

| prefix | process | role |
| --- | --- | --- |
| `preflight` | `scripts/preflight.sh` | route to the board, VPN, dataset files, console port free -- prints and continues |
| `console` | `scripts/console.sh` | the board's UART, streamed into the launch log; released on Ctrl-C |
| `dataset_relay` | `argus_sim dataset_relay_node` | serves the replay `.bin` on UDP :5010 |
| `neural_udp_receiver` | `argus_sensors` | UDP :5005 -> `/argus/neural_interface_bridge/neural_data` |
| `neural_telemetry_receiver` | `argus_sensors neural_telemetry_receiver_node` | -> `/argus/sensors/neural_telemetry` |
| `argus_inference` | `argus_inference inference_node` | loads `model:=` (or trains on the `.mat`), decodes, publishes `/cmd_vel` |
| `program` | `argus_safety_controller/tools/program.sh` | XSDB: reset, bitstream, `ps7_init`, ELF, go -- 2 s after the relay is up |

Ctrl-C ends every process. The board keeps running; only the host stops.

## Arguments

| argument | default | meaning |
| --- | --- | --- |
| `dataset` | `~/argus_data/indy_20161005_06_s120_10s.bin` | replay `.bin` for the relay |
| `mat` | `~/argus_data/indy_20161005_06.mat` | training set for the decoder |
| `model` | (empty) | saved decoder pipeline from `decode_test.py --save-model`; empty trains on the `.mat` |
| `relay`, `receiver`, `decode`, `console` | `true` | run that part |
| `console_dev` | `/dev/ttyUSB1` | board UART |
| `program` | `false` | program the FPGA and run the ELF |
| `firmware` | `~/Documents/argus_safety_controller` | checkout with `tools/program.sh` and the build outputs |

Node parameters (ports, topics) are in `config/argus.yaml`; the dataset path
is deliberately a launch argument so the file has nothing machine-specific.

## What healthy looks like

```
[preflight-1] preflight  ok    route to 192.168.1.10 via enx00e04c685e7e
[preflight-1] preflight  ok    replay dataset ... (58M)
[preflight-1] preflight  ok    console /dev/ttyUSB1 free
[console-2] console: /dev/ttyUSB1 at 115200
[dataset_relay-3] [INFO] [dataset_relay]: replay server on 0.0.0.0:5010 -- 300093 samples x 96 channels ...
[neural_udp_receiver-4] [INFO] ... listening on UDP :5005 ...
[argus_inference-6] [INFO] [argus_inference]: model path: ARGUS_MODEL_PATH=... (saved model; features=['counts', 'power'] channels=96 mult=3.5 ...)
[program-7] program: bit  19:30:12  .../argus_neural_codec.bit
[program-7] ... fpga -file ... 100% ... Successfully downloaded ...
[console-2] Initializing Argus Safety Controller...
[console-2] acq id=41435133
...
[console-2] tx 20 bin 13 skipped 0
[neural_udp_receiver-4] [INFO] ... frames ok=92 ...
[argus_inference-6] [INFO] [argus_inference]: sample=... intent=... -> vx=... wz=...
```

Then in another terminal, anything from the ROS side:

```bash
rosenv
ros2 topic hz /cmd_vel
ros2 topic echo /argus/sensors/neural_telemetry --once
```

## Hardware test in one command

```bash
scripts/hwtest.sh                        # program, run 60 s, judge
scripts/hwtest.sh --firmware             # build the firmware first (~2 min)
scripts/hwtest.sh --fabric --firmware    # build the gateware too (~3 min more)
scripts/hwtest.sh --judge ~/Documents/hwtest-<stamp>.log
```

Refuses to start if the VPN owns the route or the board is absent; builds
refuse on their own failures (a timing miss, a compile error); the run is
the launch above under a timeout with its log kept; the verdict is the
lines that matter -- `acq id`, first and last `tx`, `frames ok=`, the last
two `stream:`, the last `feat:`, the last `intent=` -- and `PASS`/`FAIL`
with the exit status to match. This is the command an unattended loop is
allowed to use, and the block that goes in a hardware-affecting commit.

## If

- **`console: /dev/ttyUSB1 is not present`** -- `ls /dev/ttyUSB*`; pass `console_dev:=`.
- **`preflight  WARN  ... held by another process`** -- a stale `screen`: `screen -ls`, `screen -X -S <id> quit`.
- **`program.tcl: missing ...`** -- build the platform and app in Vitis; the script will not program half a system.
- **`program` fails to connect or claim targets** -- a Vitis debug session holds them; stop it (red square) and rerun.
- **`acq id=... EXPECTED ... -- stale bitstream?`** -- the platform was not updated after the last Vivado build; `RUNBOOK.md`, one-time Vitis section.
- **Board runs but `No frames received`** -- it was programmed before the relay was up and never started streaming; rerun with `program:=true`, or reset the board.
