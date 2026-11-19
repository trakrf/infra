"""Read a tag's whole configuration, and apply a plan with read-back.

Works against anything with the Session interface (read, write, param, mac),
so the logic is tested without a radio.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from moko import profile as pf
from moko import protocol as p


class ApplyError(Exception):
    pass


async def _param_value(sess, key: int) -> bytes | None:
    try:
        r = await sess.param(p.param_get(key))
    except TimeoutError:
        return None
    return None if r.key == p.KEY_SET_ERROR else r.value


async def read_state(sess) -> dict:
    device = {}
    for k, uuid in p.DIS.items():
        device[k] = (await sess.read(uuid)).decode("ascii", "replace").strip("\x00")
    device["type"] = (await sess.read(p.CHAR_DEVICE_TYPE)).hex()
    mac_raw = await _param_value(sess, p.KEY_GET_MAC)
    reported = mac_raw.hex().upper() if mac_raw else None
    if reported and reported != p.bare_mac(sess.mac):
        raise ApplyError(f"tag reports MAC {reported}, expected {p.bare_mac(sess.mac)}")
    bp = await _param_value(sess, p.KEY_GET_BUTTON_POWER)
    types = p.parse_slot_types(await sess.read(p.CHAR_SLOT_TYPE))[:p.SLOTS]
    slots = []
    for i, kind in enumerate(types):
        if kind == "off":
            slots.append({"frame": "off"})
            continue
        await sess.write(p.CHAR_ADV_SLOT, bytes([i]))
        s = p.decode_slot_data(await sess.read(p.CHAR_SLOT_DATA))
        s["interval_ms"] = p.decode_interval(await sess.read(p.CHAR_INTERVAL))
        s["radio_tx_dbm"] = p.decode_s8(await sess.read(p.CHAR_RADIO_TX))
        s["ranging_dbm"] = p.decode_s8(await sess.read(p.CHAR_ADV_TX))
        trig = await _param_value(sess, p.KEY_GET_TRIGGER)
        s["trigger"] = p.decode_trigger(trig) if trig is not None else {"type": "unreadable"}
        slots.append(s)
    return {
        "mac": p.bare_mac(sess.mac),
        "device": device,
        "battery_mv": p.decode_battery(await sess.read(p.CHAR_BATTERY)),
        "button_power_off": None if bp is None else p.decode_button_power(bp),
        "slots": slots,
    }


async def write_steps(sess, steps: list[pf.Step], say: Callable[[str], None]) -> None:
    for st in steps:
        if st.char == p.CHAR_PARAMS:
            r = await sess.param(st.data)
            if r.key == p.KEY_SET_ERROR:
                raise ApplyError(f"{st.label}: tag rejected {st.data.hex()}")
        else:
            await sess.write(st.char, st.data)
        say(f"  {st.label}: {st.data.hex()}")


@dataclass
class Outcome:
    before: dict
    steps: list[pf.Step]
    after: dict | None = None
    mismatches: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return self.after is not None and not self.mismatches


async def apply(sess, want: dict, say: Callable[[str], None], dry_run: bool = False) -> Outcome:
    before = await read_state(sess)
    steps = pf.plan(before, want)
    out = Outcome(before=before, steps=steps)
    if not steps:
        say("  already matches the profile; nothing to write")
    elif dry_run:
        for st in steps:
            say(f"  would write {st.label}: {st.data.hex()}")
        out.mismatches = pf.mismatches(before, want)
        return out
    else:
        await write_steps(sess, steps, say)
    out.after = before if not steps else await read_state(sess)
    out.mismatches = pf.mismatches(out.after, want)
    return out
