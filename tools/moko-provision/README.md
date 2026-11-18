# moko — MokoSmart BeaconX Pro tag provisioning

Reads and provisions MokoSmart BeaconX Pro tags (Nordic, `BXP-D` firmware) over
BLE, through an ESPHome Bluetooth proxy, without the BeaconX Pro app. The
operating procedure is in `docs/moko-provisioning.md`. This file describes how
the tool works.

```sh
uv run moko --help
uv run pytest            # unit tests; no radio, cluster or network needed
```

## Protocol

The source is Moko's `BeaconX-Pro/01-Android-Nordic-SDK`. It was checked against
an Android HCI snoop of the BeaconX Pro app reading and changing slots on a
badge (`BXP-D_V1.1.0`) and a fob (`BXP-D_V2.0.1`). The tests use that capture's
bytes as vectors.

Two GATT services:

| Service | Characteristic | Use |
|---|---|---|
| Eddystone config `A3C87500-…` | `…02` active slot | select a slot before reading/writing it |
| | `…03` interval | u16 BE ms, 100–10000 in steps of 100 |
| | `…04` radio tx | s8 dBm: -40 -20 -16 -12 -8 -4 0 3 4 |
| | `…05` ranging | s8 dBm, calibrated RSSI |
| | `…06` lock state | `00` locked, `01` unlocked (**never written**) |
| | `…07` unlock | 16-byte challenge / response |
| | `…0A` slot data | frame byte + body (below) |
| | `…0B` factory reset | **never written** |
| | `…0C` connectable | **never written** |
| Moko `E62A0001-…` | `…02` / `…03` | command channel, write / notify |
| | `…04` device type, `…05` slot types (6 bytes), `…06` battery (u16 BE mV) | read |

**Unlock.** Read the challenge from `…07` and write back
AES-128-ECB(key, challenge). The key is the password padded to 16 bytes with
`0xFF`. Lock state reads `01` afterwards. The capture confirms the padding: the
app's responses match only with `0xFF`, not `0x00` or spaces.

**Slot data.** The first byte is the frame type:

| Byte | Frame | Body |
|---|---|---|
| `40` | Moko device info | the device name, ASCII, 1–20 chars |
| `50` | iBeacon | UUID (16) + major (u16 BE) + minor (u16 BE) |
| `20` | Eddystone-TLM | none |
| `FF` | off | none |

Writing `FF` alone is how the app deletes a slot.

**Command channel.** Write `EA key len(u16 BE) value` without response. The reply
arrives as `EB key len value`. A rejected set replies with key `0x0D`.

| Key | Purpose |
|---|---|
| `0x20` | MAC (the tool checks it matches the tag it meant to reach) |
| `0x28` / `0x38` | button long-press power-off: `01` allowed |
| `0x29` / `0x39` | trigger of the active slot; `00` = none, always advertise |

The tool sends only `0x38` and `0x39` sets (`protocol.SETTABLE_KEYS`). `0x26`
powers the tag off, and `0x89` turns off connectable, which would lock the tool
out. Neither is sent.

## Modules

| Module | Role |
|---|---|
| `protocol.py` | UUIDs, unlock, frame and field codecs, write allow-lists. Pure. |
| `profile.py` | Profile → desired state, diff → ordered writes, read-back comparison, batch CSV. Pure. |
| `device.py` | Read a whole tag; apply a plan and read back. Runs against any session-shaped object. |
| `ble.py` | One BLE session through the ESPHome proxy: connect, subscribe, unlock. |
| `onair.py` | Decode gateway `dev_list` sightings; judge them against the profile. |
| `cli.py` | `read`, `apply`, `batch`, `verify`. |

The radio lock and the broker credentials come from `gls10` (`tools/gl-s10-provision`),
a path dependency, so both tools take the same lock.

`scripts/snoop_decode.py` decodes an Android btsnoop of the app by
characteristic name. Run `uv run python scripts/snoop_decode.py LOG [MAC]`.
