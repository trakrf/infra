"""Vectors are from an Android btsnoop of the BeaconX Pro app (2026-11-18) talking
to Alice (badge, BXP-D_V1.1.0) and Eve (fob, BXP-D_V2.0.1)."""

import pytest

from moko import protocol as p

PW = "not-the-real-pw"


def test_unlock_key_pads_with_ff():
    assert p.unlock_key("abc") == b"abc" + b"\xff" * 13
    with pytest.raises(ValueError):
        p.unlock_key("x" * 17)
    with pytest.raises(ValueError):
        p.unlock_key("")


def test_unlock_response_is_aes_ecb_of_challenge():
    # Self-consistency: the capture's real password is not in the repo, so check the
    # construction (AES-128-ECB under the FF-padded key) against cryptography directly.
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    ch = bytes.fromhex("90636cf1d9ee50f5a130430af7698cca")
    e = Cipher(algorithms.AES(p.unlock_key(PW)), modes.ECB()).encryptor()
    assert p.unlock_response(PW, ch) == e.update(ch) + e.finalize()
    with pytest.raises(ValueError):
        p.unlock_response(PW, b"short")


def test_param_get_and_set_frames():
    assert p.param_get(p.KEY_GET_MAC) == bytes.fromhex("ea200000")
    assert p.param_get(p.KEY_GET_TRIGGER) == bytes.fromhex("ea290000")
    assert p.param_set(p.KEY_SET_TRIGGER, b"\x00") == bytes.fromhex("ea39000100")
    assert p.param_set(p.KEY_SET_BUTTON_POWER, b"\x01") == bytes.fromhex("ea38000101")


def test_param_reply_parse():
    r = p.ParamReply.parse(bytes.fromhex("eb200006d9ae3f727ca3"))
    assert (r.key, r.value) == (0x20, bytes.fromhex("d9ae3f727ca3"))
    assert p.ParamReply.parse(bytes.fromhex("eb390000")).value == b""
    with pytest.raises(p.ProtocolError):
        p.ParamReply.parse(bytes.fromhex("ea200000"))
    with pytest.raises(p.ProtocolError):
        p.ParamReply.parse(bytes.fromhex("eb2000"))


def test_param_set_refuses_unknown_keys():
    with pytest.raises(p.Refused):
        p.param_set(0x26, b"")  # SET_CLOSE: powers the tag off
    with pytest.raises(p.Refused):
        p.param_set(0x89, b"\x00")  # SET_CONNECTABLE: could lock us out


def test_slot_types():
    assert p.parse_slot_types(bytes.fromhex("4050ffffffff")) == ["info", "ibeacon", "off", "off", "off", "off"]
    assert p.parse_slot_types(bytes.fromhex("405020ffffff"))[2] == "tlm"
    assert p.parse_slot_types(bytes.fromhex("40ab"))[1] == "unknown:0xab"


def test_decode_slot_data_each_frame():
    assert p.decode_slot_data(bytes.fromhex("404e6f74696679")) == {"frame": "info", "name": "Notify"}
    assert p.decode_slot_data(bytes.fromhex("50eb165b98062110ab025037c882308e5f07d003e8")) == {
        "frame": "ibeacon", "uuid": "EB165B98-0621-10AB-0250-37C882308E5F", "major": 2000, "minor": 1000}
    assert p.decode_slot_data(b"\x20") == {"frame": "tlm"}
    assert p.decode_slot_data(b"\xff") == {"frame": "off"}
    assert p.decode_slot_data(b"") == {"frame": "off"}
    assert p.decode_slot_data(b"\x00\x01") == {"frame": "uid", "raw": "01"}
    assert p.decode_slot_data(b"\x99\x01") == {"frame": "unknown:0x99", "raw": "01"}


def test_encode_slot_data_round_trips_the_captured_writes():
    # Alice slot 0 write, slot 2 test iBeacon write, slot 2 turned off
    assert p.encode_slot_data({"frame": "info", "name": "Notify"}) == bytes.fromhex("404e6f74696679")
    assert p.encode_slot_data({"frame": "ibeacon", "uuid": "eb165b98-0621-10ab-0250-37c882308e33",
                               "major": 1111, "minor": 2222}) == bytes.fromhex(
        "50eb165b98062110ab025037c882308e33045708ae")
    assert p.encode_slot_data({"frame": "off"}) == b"\xff"
    assert p.encode_slot_data({"frame": "tlm"}) == b"\x20"


@pytest.mark.parametrize("bad", [
    {"frame": "info", "name": ""},
    {"frame": "info", "name": "x" * 21},
    {"frame": "info", "name": "naïve"},
    {"frame": "ibeacon", "uuid": "nope", "major": 1, "minor": 1},
    {"frame": "ibeacon", "uuid": "019E42D9-FE08-70B4-BBF2-6A6FE2470FDA", "major": 65536, "minor": 1},
    {"frame": "uid"},
])
def test_encode_slot_data_rejects(bad):
    with pytest.raises(ValueError):
        p.encode_slot_data(bad)


def test_numeric_fields():
    assert p.decode_interval(bytes.fromhex("07d0")) == 2000
    assert p.encode_interval(1000) == bytes.fromhex("03e8")
    assert p.decode_s8(b"\xfc") == -4
    assert p.decode_s8(b"\xc5") == -59
    assert p.encode_s8(-59) == b"\xc5"
    assert p.decode_battery(bytes.fromhex("0c45")) == 3141
    for bad in (50, 10_100):
        with pytest.raises(ValueError):
            p.encode_interval(bad)
    with pytest.raises(ValueError):
        p.encode_radio_tx(5)  # not one of the firmware's steps
    assert p.encode_radio_tx(-4) == b"\xfc"


def test_trigger_decode():
    assert p.decode_trigger(b"\x00") == {"type": "none"}
    assert p.decode_trigger(bytes.fromhex("05003c02")) == {"type": "move", "raw": "003c02"}
    assert p.encode_trigger({"type": "none"}) == b"\x00"
    with pytest.raises(ValueError):
        p.encode_trigger({"type": "move"})  # only "none" is writable for now


def test_button_power():
    assert p.decode_button_power(b"\x01") is True
    assert p.decode_button_power(b"\x00") is False
    assert p.encode_button_power(True) == b"\x01"


def test_uuid_handles_from_capture_map():
    # GATT handles seen in the capture -> the UUIDs the SDK names; guards typos.
    assert p.CHAR_SLOT_TYPE == "e62a0005-1362-4f28-9327-f5b74e970801"
    assert p.CHAR_BATTERY == "e62a0006-1362-4f28-9327-f5b74e970801"
    assert p.CHAR_UNLOCK == "a3c87507-8ed3-4bdf-8a39-a01bebede295"
    assert p.CHAR_RESET not in p.WRITABLE
    assert p.CHAR_LOCK_STATE not in p.WRITABLE
    assert p.CHAR_CONNECTABLE not in p.WRITABLE
