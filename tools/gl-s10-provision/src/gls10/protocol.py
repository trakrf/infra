"""GL-S10 BLE configuration protocol: framing, crypto, and command payloads.

The transport is the one GL.iNet publishes for the GL-S20; the S10's command ids
differ. Pure functions only -- nothing here touches a radio.

Frame (every write to FF01, every notification on EE01):

    FE 01 | len u16 BE (whole frame) | count u8 | crc16 u16 BE | ciphertext

  * count is per direction and starts at 1.
  * crc16 is CRC-16/XMODEM over the whole frame with the crc field zeroed.
  * ciphertext is AES-128-CBC/PKCS7 over [cmd || data], IV = ASCII "0" x 16,
    key = "goodlife--00" + upper-hex CRC-16/XMODEM(uppercase colon-free BLE MAC).

Payload fields are newline-terminated. A reply body leads with a status field;
"\\x00" means OK.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

WRITE_CHAR = "0000ff01-0000-1000-8000-00805f9b34fb"  # app -> device
NOTIFY_CHAR = "0000ee01-0000-1000-8000-00805f9b34fb"  # device -> app
IV = b"0" * 16
HEADER = b"\xfe\x01"

# S10 command ids (they differ from the S20 document).
WIFI_CONNECT = 0x01
SET_BROKER, GET_BROKER = 0x07, 0x08
SET_TOPICS, GET_TOPICS = 0x0A, 0x0B
CERT_URL = 0x1A
DEVICE_INFO = 0x21
REBOOT = 0x22
SET_CLIENT_ID, GET_CLIENT_ID = 0x27, 0x28

# 0x0c writes uplink priority with unknown semantics; 0x0d is its pair. Neither
# is ever sent -- enforced here, at the one place every frame is built.
FORBIDDEN = frozenset({0x0C, 0x0D})


class ProtocolError(Exception):
    pass


class ForbiddenCommand(ProtocolError):
    pass


def crc16_xmodem(data: bytes) -> int:
    c = 0
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def client_id(mac: str) -> str:
    """Uppercase, colon-free 12-hex form of a MAC; the unit's MQTT client id."""
    cid = mac.replace(":", "").replace("-", "").upper()
    if not re.fullmatch(r"[0-9A-F]{12}", cid):
        raise ValueError(f"not a MAC address: {mac!r}")
    return cid


def colon_mac(mac: str) -> str:
    cid = client_id(mac)
    return ":".join(cid[i : i + 2] for i in range(0, 12, 2))


def derive_key(ble_mac: str) -> bytes:
    return ("goodlife--00" + f"{crc16_xmodem(client_id(ble_mac).encode()):04X}").encode()


@dataclass(frozen=True)
class Reply:
    cmd: int | None
    body: bytes
    crc_ok: bool

    @property
    def fields(self) -> list[str]:
        """Fields after the status field, newline-split, trailing empty dropped."""
        parts = self.body.decode("utf-8", "replace").split("\n")
        if parts and parts[-1] == "":
            parts.pop()
        return parts[1:]

    @property
    def ok(self) -> bool:
        return self.crc_ok and self.body[:1] == b"\x00"


@dataclass(frozen=True)
class DeviceInfo:
    ble_mac: str
    base_mac: str
    firmware: str

    @classmethod
    def parse(cls, reply: Reply) -> DeviceInfo:
        f = reply.fields
        if len(f) < 5:
            raise ProtocolError(f"short device-info reply: {len(f)} fields")
        return cls(ble_mac=f[0], base_mac=f[1], firmware=f[4])


class Codec:
    def __init__(self, ble_mac: str):
        self.key = derive_key(ble_mac)

    def encode(self, cmd: int, data: bytes, count: int) -> bytes:
        if cmd in FORBIDDEN:
            raise ForbiddenCommand(f"command 0x{cmd:02x} is never sent")
        pt = bytes([cmd]) + data
        n = 16 - len(pt) % 16
        enc = Cipher(algorithms.AES(self.key), modes.CBC(IV)).encryptor()
        ct = enc.update(pt + bytes([n]) * n) + enc.finalize()
        frame = bytearray(HEADER + b"\x00\x00" + bytes([count & 0xFF]) + b"\x00\x00" + ct)
        frame[2:4] = len(frame).to_bytes(2, "big")
        frame[5:7] = crc16_xmodem(bytes(frame)).to_bytes(2, "big")
        return bytes(frame)

    def decode(self, frame: bytes) -> Reply:
        if frame[:2] != HEADER or len(frame) < 7:
            raise ProtocolError("not a GL-S10 frame")
        length = int.from_bytes(frame[2:4], "big")
        ct = frame[7:length]
        if len(frame) < length or not ct or len(ct) % 16:
            raise ProtocolError(f"truncated frame: have {len(frame)} of {length} bytes")
        crc_ok = crc16_xmodem(frame[:5] + b"\x00\x00" + ct) == int.from_bytes(frame[5:7], "big")
        dec = Cipher(algorithms.AES(self.key), modes.CBC(IV)).decryptor()
        pt = dec.update(ct) + dec.finalize()
        # Lenient unpad, as the proven prototype did: strip valid PKCS7, else keep.
        n = pt[-1] if pt else 0
        if 1 <= n <= 16 and pt[-n:] == bytes([n]) * n:
            pt = pt[:-n]
        return Reply(cmd=pt[0] if pt else None, body=pt[1:], crc_ok=crc_ok)


class Reassembler:
    """Long replies span several notifications; join them by the length field."""

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, chunk: bytes) -> bytes | None:
        if chunk[:2] == HEADER:
            self._buf = bytearray(chunk)
        else:
            self._buf += chunk
        if len(self._buf) >= 4 and len(self._buf) >= int.from_bytes(self._buf[2:4], "big"):
            frame, self._buf = bytes(self._buf), bytearray()
            return frame
        return None


def broker_payload(uri: str) -> bytes:
    return uri.encode() + b"\n"


def client_id_payload(cid: str) -> bytes:
    return cid.encode() + b"\n"


def topics(topic_base: str, cid: str) -> list[str]:
    return [f"{topic_base}/{cid}/{s}" for s in ("cmds", "reads", "resps")]


def topics_payload(topic_base: str, cid: str) -> bytes:
    return "".join(t + "\n" for t in topics(topic_base, cid)).encode()


def cert_url_payload(base_url: str) -> bytes:
    # The unit fetches over plain HTTP and does not follow redirects, and it
    # appends the file names to this base, so it must be an http:// directory.
    if not base_url.startswith("http://") or not base_url.endswith("/"):
        raise ValueError(f"cert base URL must be http:// and end in '/': {base_url!r}")
    return b"\x00\n" + base_url.encode() + b"\n"


def wifi_payload(ssid: str, password: str) -> bytes:
    return b"\x00\n" + ssid.encode() + b"\n" + password.encode() + b"\n"
