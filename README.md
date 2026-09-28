# argus_bringup

One command for the Argus stack.

```bash
rosenv
ros2 launch argus_bringup argus.launch.py                # host side: relay, receiver, bridge, decoder, console
ros2 launch argus_bringup argus.launch.py program:=true  # ... and program the board first
```

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
| `argus_inference` | `argus_inference inference_node` | trains on the `.mat`, decodes, publishes `/cmd_vel` |
| `program` | `argus_safety_controller/tools/program.sh` | XSDB: reset, bitstream, `ps7_init`, ELF, go -- 2 s after the relay is up |

Ctrl-C ends every process. The board keeps running; only the host stops.

## Arguments

| argument | default | meaning |
| --- | --- | --- |
| `dataset` | `~/argus_data/indy_20161005_06_s120_10s.bin` | replay `.bin` for the relay |
| `mat` | `~/argus_data/indy_20161005_06.mat` | training set for the decoder |
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
[argus_inference-6] [INFO] [argus_inference]: offline 4-way intent accuracy: 0.440
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

## If

- **`console: /dev/ttyUSB1 is not present`** -- `ls /dev/ttyUSB*`; pass `console_dev:=`.
- **`preflight  WARN  ... held by another process`** -- a stale `screen`: `screen -ls`, `screen -X -S <id> quit`.
- **`program.tcl: missing ...`** -- build the platform and app in Vitis; the script will not program half a system.
- **`program` fails to connect or claim targets** -- a Vitis debug session holds them; stop it (red square) and rerun.
- **`acq id=... EXPECTED ... -- stale bitstream?`** -- the platform was not updated after the last Vivado build; `RUNBOOK.md`, one-time Vitis section.
- **Board runs but `No frames received`** -- it was programmed before the relay was up and never started streaming; rerun with `program:=true`, or reset the board.
