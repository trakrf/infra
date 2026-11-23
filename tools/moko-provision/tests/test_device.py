import asyncio
from pathlib import Path

import pytest

from moko import device, profile as pf, protocol as p

PROFILE = pf.load(Path(__file__).parent.parent / "profiles" / "fleet.yaml")


class FakeTag:
    """A BeaconX Pro as the capture shows Alice: info + iBeacon, button power-off disabled."""

    mac = "CF:FB:F5:81:6B:C9"

    def __init__(self, reject_button=False):
        self.active = 0
        self.slots = [
            {"data": bytes.fromhex("404e6f74696679"), "interval": 1000, "tx": 0, "adv": 0, "trig": b"\x00"},
            {"data": bytes.fromhex("50eb165b98062110ab025037c882308e5f07d003e8"),
             "interval": 1000, "tx": 0, "adv": 0, "trig": b"\x00"},
        ] + [{"data": b"\xff", "interval": 1000, "tx": 0, "adv": 0, "trig": b"\x00"} for _ in range(4)]
        self.button = 0
        self.reject_button = reject_button
        self.writes: list[tuple[str, bytes]] = []

    async def read(self, uuid):
        s = self.slots[self.active]
        if uuid in p.DIS.values():
            return b"BXP-D_V1.1.0" if uuid == p.DIS["firmware"] else b"x"
        return {
            p.CHAR_DEVICE_TYPE: b"\x01",
            p.CHAR_BATTERY: bytes.fromhex("0c45"),
            p.CHAR_SLOT_TYPE: bytes(x["data"][0] for x in self.slots),
            p.CHAR_SLOT_DATA: s["data"],
            p.CHAR_INTERVAL: s["interval"].to_bytes(2, "big"),
            p.CHAR_RADIO_TX: p.encode_s8(s["tx"]),
            p.CHAR_ADV_TX: p.encode_s8(s["adv"]),
        }[uuid]

    async def write(self, uuid, data):
        self.writes.append((uuid, data))
        s = self.slots[self.active]
        if uuid == p.CHAR_ADV_SLOT:
            self.active = data[0]
        elif uuid == p.CHAR_SLOT_DATA:
            s["data"] = data
        elif uuid == p.CHAR_INTERVAL:
            s["interval"] = int.from_bytes(data, "big")
        elif uuid == p.CHAR_RADIO_TX:
            s["tx"] = p.decode_s8(data)
        elif uuid == p.CHAR_ADV_TX:
            s["adv"] = p.decode_s8(data)
        else:
            raise AssertionError(uuid)

    async def param(self, frame):
        self.writes.append((p.CHAR_PARAMS, frame))
        key, value = frame[1], frame[4:]
        if key == p.KEY_GET_MAC:
            return p.ParamReply(key, bytes.fromhex("cffbf5816bc9"))
        if key == p.KEY_GET_BUTTON_POWER:
            return p.ParamReply(key, bytes([self.button]))
        if key == p.KEY_GET_TRIGGER:
            return p.ParamReply(key, self.slots[self.active]["trig"])
        if key == p.KEY_SET_TRIGGER:
            self.slots[self.active]["trig"] = value
            return p.ParamReply(key, b"")
        if key == p.KEY_SET_BUTTON_POWER:
            if self.reject_button:
                return p.ParamReply(p.KEY_SET_ERROR, b"")
            self.button = value[0]
            return p.ParamReply(key, b"")
        raise AssertionError(frame.hex())


def run(coro):
    return asyncio.run(coro)


def test_read_state_matches_the_capture():
    st = run(device.read_state(FakeTag()))
    assert st["mac"] == "CFFBF5816BC9"
    assert st["battery_mv"] == 3141
    assert st["button_power_off"] is False
    assert st["device"]["firmware"] == "BXP-D_V1.1.0"
    assert st["slots"][0] == {"frame": "info", "name": "Notify", "interval_ms": 1000,
                              "radio_tx_dbm": 0, "ranging_dbm": 0, "trigger": {"type": "none"}}
    assert st["slots"][1]["uuid"] == "EB165B98-0621-10AB-0250-37C882308E5F"
    assert st["slots"][2:] == [{"frame": "off"}] * 4


def test_apply_then_second_run_is_a_no_op():
    tag = FakeTag()
    want = pf.render(PROFILE)
    out = run(device.apply(tag, want, lambda s: None))
    assert out.passed, out.mismatches
    assert out.after["slots"][0]["name"] == "TrakRF"
    assert out.after["slots"][0]["interval_ms"] == 10000
    assert out.after["slots"][1]["minor"] == 1000
    assert out.after["button_power_off"] is True

    tag.writes.clear()
    again = run(device.apply(tag, want, lambda s: None))
    assert again.passed and again.steps == []
    writes = [w for w in tag.writes if w[0] != p.CHAR_ADV_SLOT and w[1][:2] not in (b"\xea\x20", b"\xea\x28", b"\xea\x29")]
    assert writes == []  # nothing but reads (slot selects are how reads work)


def test_dry_run_writes_nothing():
    tag = FakeTag()
    out = run(device.apply(tag, pf.render(PROFILE), lambda s: None, dry_run=True))
    assert out.steps and out.after is None and not out.passed
    assert all(u == p.CHAR_ADV_SLOT or d[1] in (0x20, 0x28, 0x29) for u, d in tag.writes)


def test_rejected_set_fails_loudly():
    with pytest.raises(device.ApplyError, match="button power-off"):
        run(device.apply(FakeTag(reject_button=True), pf.render(PROFILE), lambda s: None))


def test_wrong_mac_is_refused():
    tag = FakeTag()
    tag.mac = "F5:DD:87:90:E8:4F"
    with pytest.raises(device.ApplyError, match="expected F5DD8790E84F"):
        run(device.read_state(tag))
