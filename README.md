# Argus Cybernetics

A neural acquisition and decoding pipeline, end to end, on hardware:
replayed motor-cortex recordings → simulated Intan headstage chips → a
spike-feature codec in Zynq fabric → UDP → ROS 2 → a linear decoder →
`/cmd_vel`. Every stage is verified independently, the codec is proven
bit-exact against its Python model on silicon, and the whole stack comes up
with one command and is tested on hardware with one command.

**Demo — the live system, six minutes, unedited:**
[asciinema.org/a/1266932](https://asciinema.org/a/1266932)
(programming the board, the boot banner, the decoder loading the validated
model, the stream at real time with zero underruns, decoded intents at 20 Hz).

This repository is `argus_bringup`: the launch, the hardware test harness,
and this overview. The stack is eight repositories; they are listed below.

## Results

| what | result | how it was measured |
| --- | --- | --- |
| Codec vs. model, simulation | bit-exact, 5,760 (bin, channel) pairs | `argus-neural-codec/sim/tb_argus_feature.vhd` against `spike_features.py` (GHDL, CI) |
| Codec vs. model, **on silicon** | bit-exact, **139,200 / 139,200** pairs, counts and power, 72.5 s | `argus_sim/tools/hw_bitexact.py`: frames captured from ROS, compared to the model run on the same samples |
| Decoder, 4-way intent, offline 5-fold CV | **53.5 ± 2.0 %** counts+power (fabric feature set) | `argus_sim/tools/decode_test.py`, full 374 s session |
| — same task, lab's spike-sorted units | 49.9 ± 1.5 % | same harness, same folds |
| — counts only / chance | 44.0 % / 34.4 % | same |
| Replay into the fabric | real time: 204 halves/s, 2.27 ms fetch, **0 underruns** after priming | firmware `stream:` counters, 90 s and 6 min runs |
| Fabric timing | WNS 0.924 ns at 125 MHz, post-route | Vivado 2026.1, XC7Z020 |
| End to end | `/cmd_vel` at 20.007 Hz, 2.9 ms jitter | `ros2 topic hz` |
| Wire integrity | ~14,500 frames, 0 size/magic/version/CRC errors | receiver counters across all runs since the lwIP fixes |

## The data path

```
 host (Ubuntu 22.04, ROS 2 Humble)                         Arty Z7-20 (Zynq XC7Z020)
 ─────────────────────────────────                         ─────────────────────────────────
 argus_data ── replay .bin ──► argus_sim                   PS (Cortex-A9, bare metal, lwIP)
                              dataset_relay_node ──UDP:5010──► replay client → BRAM halves
                                                                   │ (cacheable, flushed, acked)
                                                           PL ─────┼──────────────────────────
                                                                   ▼
                                                     sample fetcher → 3 × RHD2132 chip models
                                                                   │ SPI, 30,012 sweeps/s
                                                       SPI master ─┼─► frame assembler (raw frame)
                                                                   └─► argus_feature (the codec)
                                                                         250 Hz HPF · mean-square EMA
                                                                         3.5σ crossings + power / 50 ms
                                                                   AXI-Lite: ACQ3 register block
                                                           PS: reads the feature bank each bin
 argus_sensors ◄──UDP:5005, frame v3 (594 B)──────────────── argus_net (20 frames/s)
   neural_udp_receiver → /argus/neural_interface_bridge/neural_data
   neural_telemetry_receiver_node → /argus/sensors/neural_telemetry
 argus_inference
   inference_node (LDA on counts+power) → /cmd_vel (geometry_msgs/Twist)
```

One sweep of 96 channels every 33.3 µs; one 50 ms bin is 1,500 sweeps; one
frame per bin carries 96 crossing counts and 96 mean-square powers.

## The repositories

| repository | role | build / check |
| --- | --- | --- |
| [argus-neural-codec](https://github.com/Max-Gabriel-Susman/argus-neural-codec) | Vivado PL gateware (VHDL): SPI master, chip models, sample fetcher, frame assembler, the feature codec, AXI register block | `cd sim && make` (7 GHDL benches); `vivado -mode batch -source tools/build_bitstream.tcl` |
| [argus_safety_controller](https://github.com/Max-Gabriel-Susman/argus_safety_controller) | Vitis bare-metal firmware: replay client into BRAM, feature-bank reads, UDP telemetry; `tools/` build and program the board headlessly | `tools/build_firmware.sh`; `tools/program.sh` |
| [argus_core](https://github.com/Max-Gabriel-Susman/argus_core) | The wire contract: `argus_wire.h` (frame v3, replay protocol, CRC-16), `NeuralFrame.msg`; CI keeps the firmware's vendored copy byte-identical | `colcon build/test --packages-select argus_core` |
| [argus_sensors](https://github.com/Max-Gabriel-Susman/argus_sensors) | UDP receiver and the telemetry bridge into the ROS graph | `colcon build/test --packages-select argus_sensors` |
| [argus_inference](https://github.com/Max-Gabriel-Susman/argus_inference) | The decoder node: trains on the session's labels or loads a saved model | `colcon build/test --packages-select argus_inference` |
| [argus_sim](https://github.com/Max-Gabriel-Susman/argus_sim) | The dataset relay node and the toolchain: NWB → replay `.bin`, the bit-exact feature model, decode validation, on-silicon comparison | `colcon build/test --packages-select argus_sim` |
| [argus_data](https://github.com/Max-Gabriel-Susman/argus_data) | Dataset provenance and the scripts that fetch and derive every file (no data in git) | `shellcheck scripts/*.sh` |
| [argus_bringup](https://github.com/Max-Gabriel-Susman/argus_bringup) | This repository: the launch, the hardware harness, the overview | `colcon build --packages-select argus_bringup` |

The data are O'Doherty, Cardoso, Makin & Sabes, session `indy_20161005_06`
(Zenodo [583331](https://doi.org/10.5281/zenodo.583331) for the sorted
spikes and behaviour, [1419774](https://doi.org/10.5281/zenodo.1419774) for
the raw broadband), CC-BY-4.0. `argus_data` documents how the replay files
are made from them.

## Running it

**Hardware:** an Arty Z7-20 on USB (JTAG and UART on the one cable) and on a
gigabit Ethernet link to the host — the board is `192.168.1.10`, the host
`192.168.1.20`. **Software:** Ubuntu 22.04, ROS 2 Humble, Vivado and Vitis
2026.1 for building the gateware and firmware, GHDL and VSG for the benches.
A VPN that captures `192.168.1.0/24` must be off; preflight says so if not.

```bash
source /opt/ros/humble/setup.bash && source ~/Documents/argus_ws/install/setup.bash
ros2 launch argus_bringup argus.launch.py program:=true model:=$HOME/argus_model.pkl
```

That is the demo: it programs the board, streams the replay, and decodes
with the validated counts+power model (53.5 %). Without `model:=` the
decoder trains on the session's labels at startup instead (44.0 %, counts
only). Without `program:=true` it runs against whatever the board already
has. `Ctrl-C` ends everything; the board keeps running.

What it starts, each with its own prefix in the one terminal:

| prefix | process | role |
| --- | --- | --- |
| `preflight` | `scripts/preflight.sh` | route to the board, VPN, dataset files, console port — prints and continues |
| `console` | `scripts/console.sh` | the board's UART streamed into the log; released on Ctrl-C |
| `dataset_relay` | `argus_sim dataset_relay_node` | serves the replay `.bin` on UDP :5010, looping |
| `neural_udp_receiver` | `argus_sensors` | UDP :5005 → `/argus/neural_interface_bridge/neural_data` |
| `neural_telemetry_receiver` | `argus_sensors` | → `/argus/sensors/neural_telemetry` |
| `argus_inference` | `argus_inference inference_node` | decodes each frame → `/cmd_vel` |
| `program` | `argus_safety_controller/tools/program.sh` | XSDB: reset, bitstream, `ps7_init`, ELF, go — 2 s after the relay is up |

Arguments (`--show-args` lists them): `dataset`, `mat`, `model`, `relay`,
`receiver`, `decode`, `console`, `console_dev`, `program`, `firmware`. Node
parameters (ports, topics) are in `config/argus.yaml`; the dataset path is
an argument so the file has nothing machine-specific.

What healthy looks like:

```
[console-2] acq id=41435133
[console-2] acq features: bin 21  ch0 count 0 power 2012  ...  dropped 0
[console-2] replay ok: [0][0]=8385 [0][5]=8194 ...
[inference_node-6] model path: ARGUS_MODEL_PATH=.../argus_model.pkl (saved model; features=['counts', 'power'] ...)
[console-2] tx 20 bin 18 skipped 0
[console-2] stream: halves=2020 underruns=2 failures=0 ...
[console-2] stream: fetch avg=2263 max=2464 us (n=1020)  flush avg=417 max=418 us  rtx=0 to=0 rej=0
[neural_udp_receiver-4] frames ok=248 size=0 magic=0 ver=0 crc=0
[inference_node-6] sample=209 t=10.446 intent=2 -> vx=0.15 wz=0.70
```

`underruns` stays where it was after priming, the three error counters stay
0, `frames ok` climbs by 100 every 5 s, and an `intent=` line appears every
second (one per 20 frames decoded). Then, from any other terminal:
`ros2 topic hz /cmd_vel`.

## Testing it on hardware

```bash
scripts/hwtest.sh                        # program, run 60 s, judge
scripts/hwtest.sh --firmware             # build the firmware first (~2 min)
scripts/hwtest.sh --fabric --firmware    # build the gateware too (~3 min more)
scripts/hwtest.sh --judge ~/Documents/hwtest-<stamp>.log
```

The harness refuses to start if the VPN owns the route, the board is
absent, or processes from a previous run still hold the ports; builds
refuse on their own failures (a timing miss, a compile error); the run is
the launch above under a timeout with its log kept; and the verdict reads
only what happened after the board's boot banner: `PASS` needs the ACQ3
identity, `tx` lines advancing, and the host's frame count climbing. It
prints the `stream:` and `feat:` lines either way so a throughput or feature
regression is visible on a passing run. Every hardware-affecting commit in
these repositories carries its verdict block in the message.

## How it is verified

- **The codec.** `spike_features.py` is a bit-exact fixed-point model of the
  fabric's arithmetic (first-order 250 Hz high-pass in Q1.15 with rounding,
  winsorised mean-square EMA, 3.5σ threshold as 49/4, 1 ms refractory).
  `tb_argus_feature` drives real samples through the RTL and compares every
  (bin, channel, count, power) to the model's golden. `hw_bitexact.py`
  does the same against the board, through the full wire and ROS path.
- **The wire.** `argus_wire.h` is one header, canonical in `argus_core` and
  vendored into the firmware; `static_assert`s pin every struct size and
  CI diffs the two copies and runs a C self-test of the layout.
- **The decoder.** `decode_test.py` runs the model's features through the
  decoder's own pipeline (StandardScaler → shrinkage LDA) over the whole
  session, 5-fold, against the lab's spike sorter on the same folds.
  Sorter agreement was rejected as a metric early on; decode accuracy is
  the one that answers the question.
- **The system.** `hwtest.sh`, above, on every change that can reach the
  board.

## What it is not

- The Intan RHD2132 chips are simulated in fabric (register-accurate
  models on real SPI); no headstage or electrodes are attached.
- The neurons are a replayed macaque M1 recording, not a culture.
- The decoder's accuracy is measured offline (5-fold CV over the session);
  the live run proves the validated model decodes the fabric's features at
  rate, not an on-line accuracy figure.
- There is no feedback path from `/cmd_vel` to the board; the loop is open
  by design at this version.

## History

Built in four days of sessions in September 2026. The last two days ran as
an autonomous development loop (Claude Code, driven by a per-repo `CLAUDE.md`
work list) under hardware-in-the-loop verification: the loop could build the
gateware and firmware headlessly, program the board, run the stack, and read
its own verdict, and it found and fixed the two lwIP configuration bugs that
had capped replay throughput, took the receive path from 46 % of real time to
100 %, and wrote and ran the on-silicon bit-exactness check. Tags across the
repositories mark the milestones: `acq3-live` (the first live run),
`replay-realtime`, `codec-bitexact`, `v1.0`.

## If

- **`console: /dev/ttyUSB1 is not present`** — `ls /dev/ttyUSB*`; pass `console_dev:=`.
- **`preflight WARN route ... via nordlynx`** — disconnect the VPN.
- **`preflight WARN ... held by another process`** at startup — usually the
  launch's own console process racing the check; harmless. If the console
  then fails to attach, a stale `screen` holds the port: `screen -ls`.
- **`acq id=... EXPECTED ... -- stale bitstream?`** — the platform wasn't
  updated after a gateware build; `argus_safety_controller/RUNBOOK.md`.
- **Board runs but `No frames received`** — it was programmed before the
  relay was up; rerun with `program:=true`.
- **`Package 'argus_inference' not found` / `message type ... is invalid`**
  — the shell has base ROS but not the workspace overlay; source both.

## License

Apache-2.0.
