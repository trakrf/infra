"""Profile -> desired tag state -> the writes that get a tag there. Pure.

A tag state (what `moko read` prints, and what a profile renders to) is:

    {"button_power_off": bool,
     "slots": [ {"frame": "off"}
              | {"frame": "info", "name", <slot settings>}
              | {"frame": "ibeacon", "uuid", "major", "minor", <slot settings>}
              | {"frame": "tlm", <slot settings>} ] * 6}

<slot settings> = interval_ms, radio_tx_dbm, ranging_dbm, trigger.

`plan` rewrites a whole slot whenever anything in it differs, in the order the
BeaconX Pro app saves one (select, data, radio tx, ranging, interval,
trigger), and turns a slot off with a single slot-data write of 0xFF, as the
app does. Off slots carry no other settings worth comparing.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path

from moko import protocol as p

SETTINGS = ("interval_ms", "radio_tx_dbm", "ranging_dbm")
_SLOT_KEYS = {
    "off": set(),
    "tlm": set(SETTINGS),
    "info": set(SETTINGS),
    "ibeacon": set(SETTINGS) | {"uuid", "major", "minor"},
}
_TOP_KEYS = {"button_power_off", "name", "slots"}


class ProfileError(Exception):
    pass


@dataclass(frozen=True)
class Step:
    label: str
    char: str
    data: bytes


@dataclass(frozen=True)
class Tag:
    mac: str
    name: str | None


def load(path: Path) -> dict:
    import yaml

    with open(path) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ProfileError(f"{path}: expected a mapping at the top level")
    return data


def render(profile: dict, name: str | None = None) -> dict:
    """The full desired state for one tag."""
    extra = set(profile) - _TOP_KEYS
    if extra:
        raise ProfileError(f"unknown profile keys: {sorted(extra)}")
    slots_in = profile.get("slots") or []
    if len(slots_in) > p.SLOTS:
        raise ProfileError(f"at most {p.SLOTS} slots, profile has {len(slots_in)}")
    tag_name = name or profile.get("name")
    slots = []
    for i, s in enumerate(slots_in + [{"frame": "off"}] * (p.SLOTS - len(slots_in))):
        slots.append(_render_slot(i, dict(s), tag_name))
    state = {"button_power_off": bool(profile.get("button_power_off", True)), "slots": slots}
    for i, s in enumerate(slots):  # every live slot must encode; fail before the radio
        try:
            if s["frame"] != "off":
                p.encode_slot_data(s)
                p.encode_interval(s["interval_ms"])
                p.encode_radio_tx(s["radio_tx_dbm"])
                p.encode_s8(s["ranging_dbm"])
        except (ValueError, KeyError) as e:
            raise ProfileError(f"slot {i}: {e}") from None
    return state


def _render_slot(i: int, s: dict, name: str | None) -> dict:
    kind = s.get("frame")
    if kind not in _SLOT_KEYS:
        raise ProfileError(f"slot {i}: frame must be one of {sorted(_SLOT_KEYS)}, got {kind!r}")
    allowed = _SLOT_KEYS[kind] | {"frame"}
    extra = set(s) - allowed
    if extra:
        raise ProfileError(f"slot {i}: unknown keys for {kind}: {sorted(extra)}")
    missing = (_SLOT_KEYS[kind]) - set(s)
    if missing:
        raise ProfileError(f"slot {i}: {kind} needs {sorted(missing)}")
    if kind == "off":
        return {"frame": "off"}
    if kind == "info":
        if not name:
            raise ProfileError(f"slot {i}: info frame needs a device name (profile `name` or --name)")
        s["name"] = name
    if kind == "ibeacon":
        try:
            s["uuid"] = p.norm_uuid(str(s["uuid"]))
        except ValueError as e:
            raise ProfileError(f"slot {i}: {e}") from None
    for k, label in (("interval_ms", "interval"), ("radio_tx_dbm", "radio tx"), ("ranging_dbm", "ranging")):
        try:
            {"interval_ms": p.encode_interval, "radio_tx_dbm": p.encode_radio_tx,
             "ranging_dbm": p.encode_s8}[k](s[k])
        except (ValueError, TypeError) as e:
            raise ProfileError(f"slot {i}: {label}: {e}") from None
    s["trigger"] = {"type": "none"}
    return s


def _live(s: dict) -> bool:
    return s.get("frame") != "off"


def _slot_diff(have: dict, want: dict) -> list[str]:
    """Field names that differ, with off slots compared by frame alone."""
    if not _live(want) or not _live(have):
        return [] if have.get("frame") == want.get("frame") else ["frame"]
    keys = [k for k in want if k != "frame"]
    out = ["frame"] if have.get("frame") != want.get("frame") else []
    return out + [k for k in keys if have.get(k) != want.get(k)]


def plan(have: dict, want: dict) -> list[Step]:
    steps: list[Step] = []
    for i, (h, w) in enumerate(zip(have["slots"], want["slots"], strict=True)):
        if not _slot_diff(h, w):
            continue
        steps.append(Step(f"slot {i} select", p.CHAR_ADV_SLOT, bytes([i])))
        steps.append(Step(f"slot {i} data", p.CHAR_SLOT_DATA, p.encode_slot_data(w)))
        if not _live(w):
            continue
        steps += [
            Step(f"slot {i} radio tx", p.CHAR_RADIO_TX, p.encode_radio_tx(w["radio_tx_dbm"])),
            Step(f"slot {i} ranging", p.CHAR_ADV_TX, p.encode_s8(w["ranging_dbm"])),
            Step(f"slot {i} interval", p.CHAR_INTERVAL, p.encode_interval(w["interval_ms"])),
            Step(f"slot {i} trigger", p.CHAR_PARAMS,
                 p.param_set(p.KEY_SET_TRIGGER, p.encode_trigger(w["trigger"]))),
        ]
    if have.get("button_power_off") != want["button_power_off"]:
        steps.append(Step("button power-off", p.CHAR_PARAMS,
                          p.param_set(p.KEY_SET_BUTTON_POWER,
                                      p.encode_button_power(want["button_power_off"]))))
    return steps


def mismatches(have: dict, want: dict) -> list[str]:
    out = []
    for i, (h, w) in enumerate(zip(have["slots"], want["slots"], strict=True)):
        for k in _slot_diff(h, w):
            out.append(f"slot {i} {k}: have {h.get(k)}, want {w.get(k)}")
    if have.get("button_power_off") != want["button_power_off"]:
        out.append(f"button_power_off: have {have.get('button_power_off')}, "
                   f"want {want['button_power_off']}")
    return out


def load_batch(path: Path) -> list[Tag]:
    """CSV of `mac[, name]`; `#` lines and blanks are skipped."""
    tags: list[Tag] = []
    seen_mac: set[str] = set()
    with open(path, newline="") as f:
        rows = [r for r in csv.reader(line for line in f if line.strip() and not line.lstrip().startswith("#"))]
    for n, row in enumerate(rows, 1):
        row = [c.strip() for c in row]
        if len(row) not in (1, 2):
            raise ProfileError(f"{path} row {n}: want `mac[, name]`, got {row}")
        try:
            mac = p.colon_mac(row[0])
        except ValueError as e:
            raise ProfileError(f"{path} row {n}: {e}") from None
        if mac in seen_mac:
            raise ProfileError(f"{path}: {mac} listed twice")
        seen_mac.add(mac)
        tags.append(Tag(mac, row[1] if len(row) == 2 and row[1] else None))
    return tags
