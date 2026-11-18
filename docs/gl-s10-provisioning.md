# GL-S10 provisioning runbook

How to take a GL.iNet GL-S10 BLE gateway from the box to publishing on a TrakRF
broker, and how to re-cert the fleet when the broker's certificate chain
changes. No GL.iNet app is involved. The tool is `tools/gl-s10-provision/`
(command `gls10`); see `tools/gl-s10-provision/README.md` for how it works.

## Before you start

- **A machine on the gateway's LAN** that can reach the ESPHome Bluetooth proxy
  and serve plain HTTP to the gateway. The gateway downloads its certs from
  this machine during the run.
- **`kubectl` pointed at the GKE cluster** (`just gcp-auth`, see `docs/ops.md`).
  The broker credentials are read from secret `trakrf-mosquitto-auth` in
  `trakrf-<env>`; they are never printed.
- **`uv`** installed. The first run installs Python 3.13 and the dependencies.
- **The radio is shared.** The tool takes the same flock as ble-mcp-test's
  `bin/ble-radio-lock`, and exits 75 without sending anything if another
  session holds it. Coordinate before long runs.

```sh
cd tools/gl-s10-provision
export ESPHOME_PROXY_HOST=<proxy LAN IP>   # the ESPHome Bluetooth proxy
```

## Find the BLE MAC

The unit has a base MAC printed on the label. It is also the Wi-Fi MAC. The
other MACs are fixed offsets from it:

| Interface | MAC        | Example (`C4:DE:E2:29:A1:74` base) |
|-----------|------------|------------------------------------|
| Wi-Fi     | base       | `C4:DE:E2:29:A1:74`                |
| BLE       | base + 2   | `C4:DE:E2:29:A1:76`                |
| Ethernet  | base + 3   | `C4:DE:E2:29:A1:77`                |

The BLE MAC is what `--mac` takes. It is also the unit's MQTT client id, and the
middle segment of its topics: `trakrf.id/C4DEE229A176/{cmds,reads,resps}`.

Device payloads carry a `dev_wifi_sta_mac` field that stays the Wi-Fi MAC even
when the unit is on Ethernet. Identify a unit by `dev_ble_mac` or the client id,
never by `dev_wifi_sta_mac`.

## Pairing mode

Hold **Reset** while powering the unit on. It advertises as `GL-S10` and accepts
configuration over BLE. It ignores the new settings until it reboots out of
config mode. The tool's last step does that (`0x22`), so a run ends with the
unit back in normal operation.

A unit that is not in pairing mode is not advertising, and the tool fails with
`is not advertising -- is it in pairing mode?`.

## Provision a new unit

Read-only first, to confirm the right unit and a healthy link:

```sh
uv run gls10 info --mac C4:DE:E2:29:A1:76
```

Then provision it. How depends on whether the unit already has a network.

### Ethernet: one pass

```sh
uv run gls10 provision --mac C4:DE:E2:29:A1:76 --env preview
```

The run does the following, in order, and stops before the reboot if any write
is refused or reads back wrong:

1. Device info and current config (read-only).
2. Broker URI (`0x07`), client id (`0x27`), topics (`0x0a`).
3. Cert URL (`0x1a`): the unit downloads `ca.crt`, `client.crt` and `client.key`
   from a temporary HTTP server on this machine, within seconds and while still
   in config mode.
4. Read-back of broker, client id and topics against what was written.
5. Wait for the three cert downloads (`--fetch-timeout`, default 60 s), then
   reboot (`0x22`). If the downloads have not happened by the timeout, the tool
   reboots anyway, keeps serving, and reports `certs fetched: NO`.
6. Verify on the broker (`--verify-timeout`, default 180 s): the broker logs the
   client id connecting after the reboot, *and* a message arrives on its
   `reads` topic after that connect.

It prints `PASS <client id>` and exits 0, or `FAIL` and exits 1.

### Wi-Fi only: two passes

In config mode a unit saves a Wi-Fi network but does not join it. It joins only
after it reboots out of config mode. Until then it has no network, so it refuses
the cert URL (`0x1a` returns status 01). An out-of-box Wi-Fi unit therefore
needs two passes.

**Pass 1** saves MQTT and Wi-Fi, then reboots the unit onto Wi-Fi. The password
is read from `WIFI_PASS`, never from the command line:

```sh
WIFI_PASS='...' uv run gls10 provision --mac 0C:B8:15:8F:35:92 --env preview --ssid myssid
```

This writes broker, client id, topics and Wi-Fi (`0x01`), reads them back and
reboots. It exits 3 and prints the command for pass 2. There is nothing to
verify on the broker yet, because the unit has no certs.

**Pass 2:** put the unit back in pairing mode. It stays on Wi-Fi while in
pairing mode. Then run the cert step:

```sh
uv run gls10 recert --mac 0C:B8:15:8F:35:92 --env preview
```

This is the same as `recert` below: cert URL, downloads, reboot and broker
verify. It ends in `PASS`.

## Re-cert after the broker's intermediate changes

The unit pins the **intermediate CA that signs the broker's leaf**, not a root.
Let's Encrypt can renew onto a different intermediate, and when it does, every
unit fails TLS until it is re-certed.

Check which intermediate the broker serves now:

```sh
uv run gls10 ca --env preview
```

Compare its subject and SHA-256 with the previous run's (today: `CN=YE2`,
`97:65:8D:E8:...:BA:B4`). If they differ, re-cert each unit:

```sh
uv run gls10 recert --mac C4:DE:E2:29:A1:76 --env preview
```

`recert` writes only the cert URL, then reboots and verifies, exactly as above.
The unit must be in pairing mode for it, the same as for provisioning.

Renewals run roughly every 60 days. Check `gls10 ca` after each one; most keep
the same intermediate, and then nothing needs to happen.

## Troubleshooting

- **Exit 75, `radio busy`:** another session holds the radio. The message names
  the holder. Nothing was sent.
- **Certs never fetched:** the unit could not reach `http://<this machine>:<port>/`.
  Check it is on the same LAN and nothing blocks inbound HTTP. Pick the
  interface explicitly with `--serve-ip` and the port with `--serve-port`.
- **`0x1a cert URL ...: status 01`:** the unit has no network. On a Wi-Fi unit
  that means pass 1 has not run, or the unit did not join: check the SSID and
  password, then run pass 1 again.
- **Fetched, but no broker connect:** check the intermediate (`gls10 ca`) and
  the broker logs:
  `kubectl -n trakrf-preview logs deploy/trakrf-mosquitto -c mosquitto | grep <client id>`.
- **Connected, no reads:** the unit publishes only when it hears BLE
  advertisements, so check for nearby beacons.

## Never sent

`0x0c`/`0x0d` and `0x23`. `0x0c` writes an uplink-priority setting whose
meaning is unknown, and `0x0d` is its read. `0x23` is the GL.iNet app's
**factory reset**: it wipes the broker, topics and Wi-Fi, and it is one id away
from `0x22` reboot. The codec refuses to build any of them.

To factory-reset a unit, use the reset button in the GL.iNet app for now.
