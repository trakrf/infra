"""Decode GL-S10 frames from an Android btsnoop_hci.log.

Usage (from tools/gl-s10-provision):
    uv run python scripts/snoop_decode.py LOG BLE_MAC

Capture: enable "Bluetooth HCI snoop log" in Android developer options, do the
action in the GL.iNet app, then take a bug report; the log is under
FS/data/misc/bluetooth/logs/ in the zip. BLE_MAC is the unit's BLE address
(base MAC + 2), with or without colons.

Prints every ATT write (phone -> unit) and notification (unit -> phone) on the
connection, decrypted with the unit's key. Payloads may hold secrets (Wi-Fi and
broker passwords): do not paste the output anywhere public.

The CRC covers the ciphertext, so crc_ok=True does not mean the key was right.
Frames from another unit in the capture decrypt to junk command ids; filter on
the ids you expect.
"""
import struct
import sys

from gls10 import protocol as p

ACL = 0x02
ATT_CID = 0x0004
WRITES = (0x12, 0x52)    # write request, write command
NOTIFIES = (0x1B, 0x1D)  # notification, indication


def att_pdus(data: bytes):
    """Yield (record no, timestamp, direction, ATT PDU) from a btsnoop H4 log."""
    if data[:8] != b"btsnoop\0":
        raise SystemExit("not a btsnoop log")
    off, n, pending = 16, 0, {}
    while off + 24 <= len(data):
        _orig, incl, flags, _drops, ts = struct.unpack(">IIIIq", data[off:off + 24])
        pkt = data[off + 24: off + 24 + incl]
        off += 24 + incl
        n += 1
        if not pkt or pkt[0] != ACL:
            continue
        direction = "rx" if flags & 1 else "tx"
        hf, alen = struct.unpack("<HH", pkt[1:5])
        conn, pb = hf & 0x0FFF, (hf >> 12) & 0x3
        body = pkt[5:5 + alen]
        key = (conn, direction)
        if pb in (0x0, 0x2):  # first fragment of an L2CAP PDU
            pending[key] = bytearray(body)
        else:
            pending.setdefault(key, bytearray()).extend(body)
        buf = pending[key]
        if len(buf) < 4:
            continue
        llen, cid = struct.unpack("<HH", buf[:4])
        if len(buf) < 4 + llen:
            continue
        pdu = bytes(buf[4:4 + llen])
        pending[key] = bytearray()
        if cid == ATT_CID and pdu:
            yield n, ts, direction, pdu


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    log, mac = argv[1], argv[2]
    codec = p.Codec(mac)
    streams = {"tx": p.Reassembler(), "rx": p.Reassembler()}
    with open(log, "rb") as f:
        data = f.read()
    for n, ts, _direction, pdu in att_pdus(data):
        op = pdu[0]
        if op in WRITES:
            stream = "tx"
        elif op in NOTIFIES:
            stream = "rx"
        else:
            continue
        frame = streams[stream].feed(pdu[3:])  # skip opcode + attribute handle
        if frame is None:
            continue
        try:
            r = codec.decode(frame)
        except p.ProtocolError as e:
            print(f"#{n} {stream} undecodable: {e}")
            continue
        who = "PHONE->UNIT" if stream == "tx" else "UNIT->PHONE"
        cmd = "--" if r.cmd is None else f"0x{r.cmd:02x}"
        print(f"#{n} t={ts} {who} cmd={cmd} crc_ok={r.crc_ok} body={r.body!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
