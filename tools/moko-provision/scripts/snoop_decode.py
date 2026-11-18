"""Decode BeaconX Pro app traffic from an Android btsnoop_hci.log.

Usage (from tools/moko-provision):
    uv run python scripts/snoop_decode.py LOG [MAC]

Capture: enable "Bluetooth HCI snoop log" in Android developer options, do the
action in the BeaconX Pro app, then take a bug report (`adb bugreport`); the
log is under FS/data/misc/bluetooth/logs/ in the zip (btsnoop_hci.log, and the
previous one as btsnoop_hci.log.last).

Prints each connection and every read, write and notification by
characteristic name, decoded where the format is known. Handles are mapped to
UUIDs from the app's own discovery traffic in the same capture, so this works
on a firmware whose handle layout differs. Unlock responses are redacted: a
challenge plus its response is enough to brute-force the password offline.
"""

import struct
import sys

from moko import protocol as p

NAMES = {v: k for k, v in vars(p).items() if k.startswith("CHAR_")}
NAMES.update({v: f"DIS_{k}" for k, v in p.DIS.items()})


def records(data: bytes):
    if data[:8] != b"btsnoop\0":
        raise SystemExit("not a btsnoop log")
    off, n = 16, 0
    while off + 24 <= len(data):
        _o, incl, flags, _d, _ts = struct.unpack(">IIIIq", data[off:off + 24])
        yield n, flags, data[off + 24:off + 24 + incl]
        off += 24 + incl
        n += 1


def uuid128(b: bytes) -> str:
    h = b[::-1].hex()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def uuid16(b: bytes) -> str:
    return f"0000{b[::-1].hex()}-0000-1000-8000-00805f9b34fb"


def decode_value(name: str, v: bytes) -> str:
    try:
        if name == "CHAR_SLOT_DATA":
            return str(p.decode_slot_data(v))
        if name == "CHAR_SLOT_TYPE":
            return str(p.parse_slot_types(v))
        if name == "CHAR_INTERVAL":
            return f"{p.decode_interval(v)} ms"
        if name in ("CHAR_RADIO_TX", "CHAR_ADV_TX"):
            return f"{p.decode_s8(v)} dBm"
        if name == "CHAR_BATTERY":
            return f"{p.decode_battery(v)} mV"
        if name in ("CHAR_PARAMS", "CHAR_PARAMS_NOTIFY"):
            return f"key=0x{v[1]:02x} value={v[4:].hex()}"
        if name.startswith("DIS_"):
            return repr(v.decode("ascii", "replace"))
    except Exception as e:  # noqa: BLE001 -- show the raw bytes instead
        return f"(undecodable: {e})"
    return ""


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    only = p.bare_mac(argv[2]) if len(argv) == 3 else None
    peers: dict[int, str] = {}
    handles: dict[tuple[int, int], str] = {}
    pending: dict[tuple[int, str], bytearray] = {}
    last_read: dict[int, int] = {}
    with open(argv[1], "rb") as f:
        data = f.read()
    for n, flags, pkt in records(data):
        if pkt[:2] == b"\x04\x3e" and len(pkt) > 15 and pkt[3] in (0x01, 0x0A):
            h = struct.unpack("<H", pkt[5:7])[0]
            peers[h] = pkt[9:15][::-1].hex().upper()
            if only in (None, peers[h]):
                print(f"#{n} connect {peers[h]}")
            continue
        if not pkt or pkt[0] != 0x02:
            continue
        hf, alen = struct.unpack("<HH", pkt[1:5])
        conn, pb, d = hf & 0xFFF, (hf >> 12) & 3, "rx" if flags & 1 else "tx"
        k = (conn, d)
        if pb in (0, 2):
            pending[k] = bytearray(pkt[5:5 + alen])
        else:
            pending.setdefault(k, bytearray()).extend(pkt[5:5 + alen])
        buf = pending[k]
        if len(buf) < 4 or len(buf) < 4 + struct.unpack("<H", buf[:2])[0]:
            continue
        ln, cid = struct.unpack("<HH", buf[:4])
        pdu = bytes(buf[4:4 + ln])
        pending[k] = bytearray()
        if cid != 4 or not pdu or (only and peers.get(conn) != only):
            continue
        op = pdu[0]
        if op == 0x09 and len(pdu) > 2:  # Read By Type response: characteristic declarations
            size = pdu[1]
            for i in range(2, len(pdu) - size + 1, size):
                e = pdu[i:i + size]
                if size in (7, 21):
                    vh = struct.unpack("<H", e[3:5])[0]
                    handles[(conn, vh)] = uuid128(e[5:]) if size == 21 else uuid16(e[5:])
            continue
        name_of = lambda h: NAMES.get(handles.get((conn, h), ""), f"handle 0x{h:04x}")  # noqa: E731
        if op == 0x0A:
            last_read[conn] = struct.unpack("<H", pdu[1:3])[0]
            continue
        if op == 0x0B and conn in last_read:
            name = name_of(last_read.pop(conn))
            v = pdu[1:]
            print(f"#{n} read  {name}: {v.hex()} {decode_value(name, v)}")
        elif op in (0x12, 0x52):
            h = struct.unpack("<H", pdu[1:3])[0]
            name, v = name_of(h), pdu[3:]
            if name == "CHAR_UNLOCK":
                print(f"#{n} write {name}: <unlock response, {len(v)} bytes, redacted>")
            elif name != f"handle 0x{h:04x}" or v not in (b"\x01\x00", b"\x02\x00"):
                print(f"#{n} write {name}: {v.hex()} {decode_value(name, v)}")
        elif op in (0x1B, 0x1D):
            h = struct.unpack("<H", pdu[1:3])[0]
            name, v = name_of(h), pdu[3:]
            print(f"#{n} notify {name}: {v.hex()} {decode_value(name, v)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
