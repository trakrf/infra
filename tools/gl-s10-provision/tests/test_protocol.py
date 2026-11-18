import pytest

from gls10 import protocol as p


def test_crc16_xmodem_check_value():
    # The CRC-16/XMODEM catalogue check value.
    assert p.crc16_xmodem(b"123456789") == 0x31C3


@pytest.mark.parametrize("mac", ["C4DEE229A176", "c4:de:e2:29:a1:76", "C4:DE:E2:29:A1:76"])
def test_key_derivation_matches_known_unit(mac):
    assert p.derive_key(mac) == b"goodlife--002691"


def test_encode_decode_roundtrip():
    codec = p.Codec("C4DEE229A176")
    frame = codec.encode(0x27, b"C4DEE229A176\n", count=3)
    assert frame[:2] == b"\xfe\x01"
    assert int.from_bytes(frame[2:4], "big") == len(frame)
    assert frame[4] == 3
    reply = codec.decode(frame)
    assert reply.crc_ok
    assert reply.cmd == 0x27
    assert reply.body == b"C4DEE229A176\n"


def test_decode_flags_bad_crc():
    codec = p.Codec("C4DEE229A176")
    frame = bytearray(codec.encode(0x21, b"", count=1))
    frame[5] ^= 0xFF
    assert not codec.decode(bytes(frame)).crc_ok


def test_decode_rejects_truncated_frame():
    frame = p.Codec("C4DEE229A176").encode(0x08, b"", count=1)
    with pytest.raises(p.ProtocolError):
        p.Codec("C4DEE229A176").decode(frame[:-3])


@pytest.mark.parametrize("cmd", [0x0C, 0x0D])
def test_forbidden_commands_are_refused(cmd):
    with pytest.raises(p.ForbiddenCommand):
        p.Codec("C4DEE229A176").encode(cmd, b"", count=1)


def test_reply_status_and_fields():
    r = p.Reply(cmd=0x08, body=b"\x00\nmqtts://u:pw@h:8883\n", crc_ok=True)
    assert r.ok
    assert r.fields == ["mqtts://u:pw@h:8883"]
    assert not p.Reply(cmd=0x07, body=b"\x01\n", crc_ok=True).ok
    assert not p.Reply(cmd=0x07, body=b"\x00\n", crc_ok=False).ok
    assert not p.Reply(cmd=0x07, body=b"", crc_ok=True).ok


def test_reassembler_joins_split_notifications():
    codec = p.Codec("C4DEE229A176")
    frame = codec.encode(0x21, b"\x00\n" + b"x" * 60 + b"\n", count=1)
    ra = p.Reassembler()
    assert ra.feed(frame[:20]) is None
    assert ra.feed(frame[20:40]) is None
    assert ra.feed(frame[40:]) == frame


def test_reassembler_restarts_on_new_header():
    codec = p.Codec("C4DEE229A176")
    f1 = codec.encode(0x21, b"\x00\n" + b"y" * 40, count=1)
    f2 = codec.encode(0x08, b"\x00\n", count=2)
    ra = p.Reassembler()
    assert ra.feed(f1[:10]) is None  # abandoned partial
    assert ra.feed(f2) == f2


def test_payload_builders():
    assert p.broker_payload("mqtts://u:p@h:8883") == b"mqtts://u:p@h:8883\n"
    assert p.topics_payload("trakrf.id", "C4DEE229A176") == (
        b"trakrf.id/C4DEE229A176/cmds\ntrakrf.id/C4DEE229A176/reads\n"
        b"trakrf.id/C4DEE229A176/resps\n"
    )
    assert p.cert_url_payload("http://10.0.0.5:8000/abc/") == b"\x00\nhttp://10.0.0.5:8000/abc/\n"
    assert p.wifi_payload("ssid", "pw") == b"\x00\nssid\npw\n"


def test_cert_url_must_be_plain_http_directory():
    with pytest.raises(ValueError):
        p.cert_url_payload("https://example/abc/")
    with pytest.raises(ValueError):
        p.cert_url_payload("http://example/abc")


def test_client_id_normalises_mac():
    assert p.client_id("c4:de:e2:29:a1:76") == "C4DEE229A176"
    with pytest.raises(ValueError):
        p.client_id("C4DEE229A1")


def test_device_info_parse():
    body = b"\x00\n0C:B8:15:1E:68:3A\n0C:B8:15:1E:68:38\n06c3e0138cdfde53\nmde6838\n3.0.3\n\x00\n"
    info = p.DeviceInfo.parse(p.Reply(cmd=0x21, body=body, crc_ok=True))
    assert info.ble_mac == "0C:B8:15:1E:68:3A"
    assert info.base_mac == "0C:B8:15:1E:68:38"
    assert info.firmware == "3.0.3"
