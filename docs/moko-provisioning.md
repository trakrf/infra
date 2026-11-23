# Moko BLE tag provisioning runbook

How to read and provision MokoSmart BeaconX Pro tags (the Notify badges, the
fobs, the M2) without the BeaconX Pro app, and how to check the result on the
GL-S10 gateways. The tool is `tools/moko-provision/` (command `moko`); see
`tools/moko-provision/README.md` for the protocol.

## Before you start

- **A machine that can reach the ESPHome Bluetooth proxy**, within BLE range of
  the tags. The tool talks to tags only through the proxy.
- **The tag password.** The tags are locked with an Eddystone-style password
  of up to 16 characters. It lives in the password manager, and locally in
  `.env.local`, never in this repo:
  - `NOTIFY_BLE_PASSWORD`: the Notify badges and the fobs. This is the default.
  - `MOKO_BLE_PASSWORD`: Moko's factory default, for tags nobody has re-locked.
    The M2 (Tool Cart 1) uses this one. Use `--password-env MOKO_BLE_PASSWORD`.
    A batch uses one password, so batch the M2 separately.

  `--password-file <file>` reads it from a file instead. The password is never
  taken from the command line and never printed. A wrong password fails with
  `stayed locked after unlock`. Nothing is written in that case.
- **`kubectl` pointed at the GKE cluster** (`just gcp-auth`, see `docs/ops.md`),
  only for `verify`. It reads the broker login from `trakrf-mosquitto-auth`.
- **The radio is shared.** `moko` takes the same flock as ble-mcp-test's
  `bin/ble-radio-lock`, and exits 75 without sending anything if another session
  holds it. Tell the ble-mcp-test agent on cc2cc before a long batch.

```sh
cd tools/moko-provision
export ESPHOME_PROXY_HOST=<proxy LAN IP>
direnv exec ../.. uv run moko --help   # direnv exec: loads .env.local's passwords
```

## How the Notify tags shipped

A record of Moko's factory preset for the Notify-branded badges and fobs, as
Moko's sales engineer confirmed it. Moko numbers slots from 1; `moko` numbers
them from 0.

| Moko slot | `moko` slot | Frame | Preset |
|---|---|---|---|
| 1 | 0 | Device info | name `Notify`, ranging 0 dBm, tx 0 dBm, every 2000 ms |
| 2 | 1 | iBeacon | UUID `EB165B98-0621-10AB-0250-37C882308E5F`, major 2000, minor 1000, ranging 0 dBm, tx 0 dBm, every 2000 ms |
| 3 | 2 | TLM | tx 0 dBm, every 2000 ms |

- **Password:** the Notify password (`NOTIFY_BLE_PASSWORD`), not Moko's factory
  default.
- **Button:** could not turn the tag off. The order was for a custody
  deployment.
- **Identity:** every tag shipped with the same UUID, major and minor.

## Read a tag

```sh
direnv exec ../.. uv run moko read --mac F5DD8790E84F > bob.json
```

The JSON has the device info (model, firmware, hardware, production date), the
battery in mV, whether a long button press can power the tag off, and all six
slots: frame, name or iBeacon UUID/major/minor, interval, radio tx power,
ranging (calibrated RSSI), and trigger. Keep it as the audit record of the tag
before you change it.

A slot's trigger of `none` means the slot always advertises. Anything else
(`move`, `double_click`, ...) means it advertises only after that event, which
is how a tag goes quiet while it sits still.

## Apply the profile

`profiles/fleet.yaml` is the fleet profile. Each setting has its reason in a
comment beside it. In short:

| | Setting |
|---|---|
| Slot 0 | Moko device-info frame (battery + name) every 10 s |
| Slot 1 | iBeacon, fleet UUID, major 2000, minor 1000, every 1 s |
| Slots 2-5 | off |
| Triggers | none on every live slot, so nothing goes quiet when stationary |
| Name | `TrakRF` |
| Button | long press powers the tag off |

A custody deployment, which was the Notify badges' original use, wants
`button_power_off: false` so a wearer cannot switch a badge off. Copy the
profile for that, rather than editing the fleet one.

```sh
direnv exec ../.. uv run moko apply --mac F5DD8790E84F --name Bob --dry-run
direnv exec ../.. uv run moko apply --mac F5DD8790E84F --name Bob --verify-env preview
```

`apply` reads the tag, writes only the slots that differ (each one rewritten in
the order the app uses), then reads the whole tag back. PASS means the read-back
matches the profile. A second run against a matching tag writes nothing and
reports `no-op`. `--verify-env` then watches the gateways (see below).

A tag's identity is its BLE MAC. That is what the platform keys reads and asset
membership on. The iBeacon UUID, major and minor are the same on every tag in
the fleet and identify no tag. `--name` is optional and defaults to the
profile's `name`.

## Batch

A CSV of `mac[, name]`; `#` lines are comments:

```
# Organized Chaos, preview
CFFBF5816BC9, Alice
F5DD8790E84F, Bob
```

```sh
direnv exec ../.. uv run moko batch --file oc-tags.csv --dry-run
direnv exec ../.. uv run moko batch --file oc-tags.csv --verify-env preview
```

The file is rejected before any radio traffic if a MAC repeats. One
tag failing (out of range, wrong password) does not stop the others. The table
at the end has a row per tag, and the exit is 1 if any failed.

## Verify on air

```sh
direnv exec ../.. uv run moko verify --mac F5DD8790E84F --env preview --verify-seconds 90
```

This subscribes to `trakrf.id/+/reads` on the env's broker and decodes every
advertisement of that tag that any GL-S10 reports. It fails if:

- a frame the profile turns on is not seen, or one it turns off still is
- the iBeacon UUID/major/minor is not the profile's
- telemetry arrives at less than half the profile's interval (the old 1-2 s)
- the iBeacon arrives at more than 5 times its interval
- no battery reading decodes, or it is outside 2000-3700 mV

Intervals are measured per gateway, and the gateway that heard the tag most often
is used. Gateways miss packets, so a measured interval is an upper bound. A
gateway also reports one advertising event as a burst of sightings within a few
hundred ms (seen on Bob at 10 s), so sightings that close together count as one
event. Give
the window at least three telemetry intervals: the default 60 s is enough for 10 s.

Straight after a write, a tag can advertise far faster than profiled for a
minute or two. This was seen on Bob and Dave, and both settled to the profile.
If `apply --verify-env` fails on telemetry rate alone while the read-back
passed, wait two minutes and run `moko verify` again before investigating.

The gateways hear further than the proxy does. A tag the gateways report can
still be out of the proxy's reach (`is not advertising`): bring it closer to
the proxy.

## Connection quirks

- Tags connect without pairing mode. A tag that keeps advertising but refuses
  connections has probably had "connectable" turned off. The tool never writes
  that setting, and recovering such a tag has not been tried yet.
- A tag that is not advertising cannot be reached: it is powered off, out of
  range, or has a flat cell. `moko` waits `--scan-seconds` (20) before failing.
- Slot settings are read and written by selecting the slot first, so reads and
  writes on one tag must not interleave. One session per tag, one tag at a time.
- The slowest allowed interval is 10 s, and intervals are whole tenths of a
  second. The app enforces the same range.

## Password rotation

`moko` does not change passwords. It refuses to write the lock-state
characteristic, because a wrong write locks the tag against every later run.
Rotate with the BeaconX Pro app (Setting tab, password), one tag at a time, then:

1. Update the password manager.
2. Update `NOTIFY_BLE_PASSWORD` in `.env.local`.
3. Run `moko read` against each rotated tag to prove the new password unlocks it.

## Recovering a tag

- **Unknown password.** Try `--password-env MOKO_BLE_PASSWORD` (factory
  default). Otherwise the tag needs a factory reset.
- **Factory reset** is in the app's Setting tab. The tool refuses to send it.
  The SDK says only that the tag must be reconnected afterwards. It does not say
  which settings return to factory values. Treat a reset tag as unknown: run
  `moko read` with each password, then `moko apply`.
- **Powered off.** With `button_power_off: true`, a long press powers the tag
  off. With it `false`, the button cannot power it off. How a powered-off tag
  wakes has not been checked on these models yet. Note it here once it has.

## Capturing the app's traffic

When a firmware does something the tool does not expect, capture the app doing
it: enable the Android HCI snoop log, do the action in the BeaconX Pro app, take
`adb bugreport`, and decode it from the repo root:

```sh
uv run --project tools/moko-provision python tools/moko-provision/scripts/snoop_decode.py \
  btsnoop_hci.log F5DD8790E84F
```

Unlock responses are redacted from the output. Do not post the raw log anywhere
public: it holds the challenge/response pairs, which is enough to brute-force the
password offline.
