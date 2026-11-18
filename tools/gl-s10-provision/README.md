# gls10 — GL-S10 BLE provisioning

Configures GL.iNet GL-S10 BLE gateways over BLE, through an ESPHome Bluetooth
proxy, without the GL.iNet app. The operating procedure is in
`docs/gl-s10-provisioning.md`. This file describes how the tool works.

```sh
uv run gls10 --help
uv run pytest            # unit tests; no radio, cluster or network needed
```

## Protocol

The transport matches GL.iNet's published GL-S20 BLE network configuration API:
write to characteristic `FF01`, notify on `EE01`. The S10's command ids differ
from that document.

```
FE 01 | len u16 BE (whole frame) | count u8 | crc16 u16 BE | ciphertext
```

- `count` is per direction and starts at 1.
- `crc16` is CRC-16/XMODEM over the whole frame, with the crc field zeroed.
- The ciphertext is AES-128-CBC with PKCS7 padding, IV = ASCII `"0"` x 16, over
  `[cmd || data]`.
- The key is `"goodlife--00"` + the upper-hex CRC-16/XMODEM of the uppercase,
  colon-free BLE MAC. For `C4DEE229A176` that gives `goodlife--002691`.
- Payload fields are newline-terminated. A reply's first field is its status;
  `\x00` means OK. Long replies span several notifications and are reassembled
  by the length field.

| Cmd           | Purpose                    | Payload                                   |
|---------------|----------------------------|-------------------------------------------|
| `0x07`/`0x08` | set / get broker URI       | `mqtts://user:pass@host:port`             |
| `0x27`/`0x28` | set / get client id        | `<MAC>`                                   |
| `0x0a`/`0x0b` | set / get topics           | `<cmds>\n<reads>\n<resps>`                |
| `0x01`        | join Wi-Fi                 | `\x00\n<ssid>\n<password>`                |
| `0x03`/`0x04` | set / get Ethernet         | `<flag>\n<ip>\n<mask>\n<gw>` (unused here) |
| `0x1a`        | cert base URL              | `\x00\n<http://host/dir/>`                |
| `0x1d`/`0x1e` | OTA / OTA status           | `0\n<firmware URL>` (unused here)         |
| `0x21`        | device info                | —                                         |
| `0x22`        | reboot / leave config mode | —                                         |
| `0x23`        | factory reset (never sent) | —                                         |

`protocol.Codec.encode` refuses `0x0c`/`0x0d` and `0x23`:

- `0x0c` writes an uplink-priority setting whose meaning is unknown. `0x0d` is
  its read; the GL.iNet app sends it on every connect. It is banned along with
  `0x0c` until that command is understood.
- `0x23` is the app's factory reset. It is one id away from `0x22`, and a typo
  must not be able to wipe a unit.

Read commands the app also sends: `0x0f` timezone (`UTC-8`), `0x13`
(`0\n04:00`) and `0x2a` (`1\n80\n48`). The meaning of the last two is unknown.

## Modules

| Module          | Role                                                                |
|-----------------|---------------------------------------------------------------------|
| `protocol.py`   | Framing, crypto, reassembly, payload builders. Pure.                |
| `plan.py`       | The ordered writes for `provision` and `recert`. Pure.              |
| `certs.py`      | Fetches the broker's chain and picks the intermediate that signed the leaf; generates the dummy client pair. |
| `certserver.py` | In-memory plain-HTTP server under a random path token; records the three GETs. |
| `creds.py`      | Broker credentials from `trakrf-mosquitto-auth`; masks every secret in output. |
| `lock.py`       | `flock` on `/tmp/ble-mcp-test.radio.lock`, the shared radio's lock. |
| `ble.py`        | One BLE session through the ESPHome proxy.                          |
| `verify.py`     | Broker log connect line plus a `reads` message after it → PASS/FAIL. |
| `cli.py`        | `ca`, `info`, `provision`, `recert`.                                |

`scripts/snoop_decode.py` decodes an Android btsnoop capture of the GL.iNet
app, which is how the command map above was read. Run
`uv run python scripts/snoop_decode.py LOG BLE_MAC`; its docstring says how to
capture.

## Why the cert step looks like this

- **Only the intermediate goes in `ca.crt`.** The unit pins that one cert, and
  a bundle or the root does not work. So the file is cut from the broker's live
  chain at run time, rather than copied from a file that goes stale.
- **The client pair is a throwaway.** The broker does not ask for client certs,
  but the unit refuses a cert update without all three files.
- **Plain HTTP from this machine.** The unit fetches only plain HTTP and does
  not follow redirects, so an HTTPS-forcing host such as Cloudflare is out. A
  unit in BLE range is on this LAN in practice. A hosted endpoint is only worth
  building once a site puts its gateways on an isolated VLAN.
