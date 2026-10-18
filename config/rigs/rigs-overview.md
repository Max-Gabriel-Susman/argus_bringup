# Rig profiles

A rig profile describes one hardware configuration of Argus: which headstage chips are on the bus, how many, and where each chip's signal comes from. One YAML file per rig lives in this directory. The build, the firmware and the launch all read the same file, so a rig is switched by naming it rather than by editing code.

Status as of 2026-10-18. The profiles are declarative for now: the tooling that reads them (`argus_rig.py`, `program.sh --rig`, `argus.launch.py rig:=`) arrives with ACQ4, step 5.3.

## Naming

```text
<chip><count>_<source>
```

- **chip:** `rhd` for the Intan RHD2132 (32 channels, record only), `rhs` for the Intan RHS2116 (16 channels, record and stimulate).
- **count:** how many chips are on the bus, 1 to 3.
- **source:** where the signal comes from (see below).

The name is a label for people. The tooling reads the fields inside the file and never parses the name.

## Signal sources

| Source | The chips are | Their samples come from |
| --- | --- | --- |
| `replay` | simulated chip models in the FPGA fabric | a recorded dataset, streamed from the workstation by the dataset relay into BRAM and fed to the models by `argus_sample_fetch` |
| `ident` | simulated chip models in the FPGA fabric | each model's built-in identity pattern (chip, channel and sample index stamped into every word). A self-test that needs no host data. |
| `live` | real chips on the FPGA pins | real electrodes |
| hybrid | a mix of real and simulated chips, set per lane by `lane_src` | real electrodes on the `pins` lanes, a recording on the `model` lanes |

Replay is how v1.0 runs. The models answer the SPI master exactly as real chips would, so everything downstream of the bus is the same code whether the data is recorded or live.

## The rigs

| Rig | Chips | Signal source | Channels | Status |
| --- | --- | --- | --- | --- |
| `rhd3_replay` | 3 simulated RHD2132 | the Indy recording | 96 | **Runs today.** This is the v1.0 system and the default. |
| `rhd3_ident` | 3 simulated RHD2132 | the identity pattern | 96 | The fabric supports it today (CTRL.ext_mode clear). No firmware or launch path selects it yet; that comes with ACQ4 P5. |
| `rhs1_replay` | 1 simulated RHS2116 | the Indy recording, first 16 channels | 16 | Needs ACQ4: the RHS2116 model and master (P3, P4) and the per-chip-type build (P5). |
| `rhd1_hybrid` | 1 real RHD2132 on lane 0, 2 simulated on lanes 1 and 2 | real electrodes on lane 0, the recording on lanes 1 and 2 | 96 (32 live, 64 replayed) | Needs ACQ4, an RHD2132 headstage, the LVDS adapter and the `ext_pins` build. |
| `rhd1_live` | 1 real RHD2132 | real electrodes | 32 | Needs ACQ4, an RHD2132 headstage, the LVDS adapter and the `ext_pins` build. |
| `rhs1_live` | 1 real RHS2116 | real electrodes; stimulation later | 16 | Needs ACQ4, an RHS2116 headstage with its stimulation supplies, and the `ext_pins` build. Records only: stimulation stays disabled until Direction 3 adds the safety controller's arm and disarm logic. |

What each rig is for:

- **`rhd3_replay`:** the reference rig. Every bit-exact check (`hw_bitexact.py`, the feature golden) is defined against it.
- **`rhd3_ident`:** bring-up and debugging without the workstation's relay. If the identity pattern arrives intact, the SPI bus, the lanes and the frame path are good.
- **`rhs1_replay`:** exercises the RHS2116 chain end to end before any RHS hardware exists.
- **`rhd1_hybrid`:** checks a real chip against a known reference in the same frame. Lanes 1 and 2 carry data whose correct answer is already known.
- **`rhd1_live`:** the first real-electrode rig, and the one the Direction 1 culture experiment starts on.
- **`rhs1_live`:** the closed-loop rig. Recording only until Direction 3.

## Fields

| Field | Values | When it applies | Meaning |
| --- | --- | --- | --- |
| `chip_type` | `rhd2132`, `rhs2116` | build time | Which SPI master and chip model the bitstream contains. Each type has its own bitstream; switching type means programming the other one. |
| `chip_mask` | `0b001` to `0b111` | run time | The lanes in use. Masked-out lanes read as zeros and are skipped by the codec. |
| `lane_src` | list of `model`, `pins`, `off`, one per lane | run time | Where each lane's MISO comes from: a simulated chip, a real chip on the pins, or nothing. `pins` needs a build with `ext_pins: true`. |
| `source` | `replay`, `ident`, `live` | run time | What the `model` lanes are fed. `live` means there are no model lanes. A hybrid rig uses `replay` or `ident` here and gets its live lanes from `lane_src`. |
| `dataset` | path to a replay `.bin` | run time | The recording the relay streams. Only read when `source: replay`. |
| `ext_pins` | `true`, `false` (default) | build time | Routes the SPI bus to the FPGA pins so real chips can be attached. |
| `max_chips` | 1 to 3 (default 3) | build time | How many MISO lanes the bitstream has. |

Two things about how the fields interact:

- **Detection usually sets the mask for you.** At startup the fabric reads each lane's ROM and works out which chips are actually there, and `CHIP_MASK` defaults to that. A profile's `chip_mask` states what you expect, so `hwtest.sh` can fail loudly when the hardware doesn't match.
- **Channel numbers never move.** Chip `k`, channel `i` is always channel `k × channels_per_chip + i`. Unplugging a chip leaves a gap instead of renumbering the channels after it.

## Switching rigs

Once the tooling lands (ACQ4, step 5.3):

```bash
program.sh --rig rhs1_replay
ros2 launch argus_bringup argus.launch.py rig:=rhs1_replay
```

`program.sh` picks the bitstream for the rig's `chip_type`. The firmware applies the mask and lane sources at boot. The launch starts the dataset relay when `source: replay`, and the receiver warns if the frames it gets don't match the rig.

Changing the chip type costs a reprogram. Changing the count or the lane sources on the same chip type currently costs a firmware rebuild, about 30 seconds headless, because those values are compiled in. A config packet from the host would remove that rebuild; it's planned but not yet scheduled.

## Adding a rig

1. Copy the closest existing profile and rename it using the scheme above.
2. Keep the two header comment lines (`Chips` and `Signal Source`) accurate. They're what someone reads first.
3. Add a row to the table in this file.
