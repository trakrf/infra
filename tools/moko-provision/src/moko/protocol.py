"""BeaconX Pro (Nordic, BXP-D firmware) GATT protocol. Pure: no radio.

Two services carry the configuration:

* the Eddystone GATT configuration service (A3C87500-...), per slot: select the
  slot on ADV_SLOT, then read/write SLOT_DATA, INTERVAL, RADIO_TX, ADV_TX;
* Moko's service (E62A0001-...): read-only slot types and battery, plus a
  command channel -- write `EA key len16 value` to PARAMS (write without
  response), the reply arrives as `EB key len16 value` on PARAMS_NOTIFY.

Unlock is the Eddystone challenge: read 16 bytes from UNLOCK, write back
AES-128-ECB(key, challenge). The key is the password padded to 16 bytes with
0xFF -- confirmed against the BeaconX Pro app's traffic, not just the SDK.
Lock state reads 0x01 when unlocked.

Sources: BeaconX-Pro/01-Android-Nordic-SDK (ParamsKeyEnum, OrderCHAR,
SlotFrameTypeEnum, TxPowerEnum, ParamsTask) and the app capture.
"""

from __future__ import annotations

import re
import struct
from dataclasses import dataclass

_EDDY = "a3c875{:02x}-8ed3-4bdf-8a39-a01bebede295"
_MOKO = "e62a00{:02x}-1362-4f28-9327-f5b74e970801"

CHAR_ADV_SLOT = _EDDY.format(0x02)
CHAR_INTERVAL = _EDDY.format(0x03)
CHAR_RADIO_TX = _EDDY.format(0x04)
CHAR_ADV_TX = _EDDY.format(0x05)  # "ranging data": RSSI at 0 m (Eddystone) / 1 m (iBeacon)
CHAR_LOCK_STATE = _EDDY.format(0x06)
CHAR_UNLOCK = _EDDY.format(0x07)
CHAR_SLOT_DATA = _EDDY.format(0x0A)
CHAR_RESET = _EDDY.format(0x0B)  # factory reset -- never written
CHAR_CONNECTABLE = _EDDY.format(0x0C)

CHAR_PARAMS = _MOKO.format(0x02)
CHAR_PARAMS_NOTIFY = _MOKO.format(0x03)
CHAR_DEVICE_TYPE = _MOKO.format(0x04)
CHAR_SLOT_TYPE = _MOKO.format(0x05)
CHAR_BATTERY = _MOKO.format(0x06)
CHAR_DISCONNECT_NOTIFY = _MOKO.format(0x07)

# Device Information Service
DIS = {
    "manufacturer": "00002a29-0000-1000-8000-00805f9b34fb",
    "model": "00002a24-0000-1000-8000-00805f9b34fb",
    "production_date": "00002a25-0000-1000-8000-00805f9b34fb",
    "firmware": "00002a26-0000-1000-8000-00805f9b34fb",
    "hardware": "00002a27-0000-1000-8000-00805f9b34fb",
    "software": "00002a28-0000-1000-8000-00805f9b34fb",
}

# The only characteristics Session.write will touch. Lock state (password
# change), reset and connectable are deliberately absent: a wrong write to any
# of them wipes a tag or locks us out of it.
WRITABLE = frozenset({CHAR_ADV_SLOT, CHAR_INTERVAL, CHAR_RADIO_TX, CHAR_ADV_TX,
                      CHAR_SLOT_DATA, CHAR_UNLOCK, CHAR_PARAMS})

SLOTS = 6
LOCK_UNLOCKED = (0x01, 0x02)

# Moko command-channel keys (ParamsKeyEnum).
KEY_GET_MAC = 0x20
KEY_GET_BUTTON_POWER = 0x28
KEY_SET_BUTTON_POWER = 0x38
KEY_GET_TRIGGER = 0x29  # for the active slot
KEY_SET_TRIGGER = 0x39
KEY_SET_ERROR = 0x0D  # the tag's reply when it rejects a set
SETTABLE_KEYS = frozenset({KEY_SET_BUTTON_POWER, KEY_SET_TRIGGER})

FRAMES = {0x00: "uid", 0x10: "url", 0x20: "tlm", 0x40: "info", 0x50: "ibeacon",
          0x60: "axis", 0x70: "th", 0xFF: "off"}
FRAME_BYTE = {v: k for k, v in FRAMES.items()}

TRIGGERS = {0: "none", 1: "temperature", 2: "humidity", 3: "double_click",
            4: "triple_click", 5: "move", 6: "light", 7: "single_click", 8: "tamper"}

RADIO_TX_STEPS = (-40, -20, -16, -12, -8, -4, 0, 3, 4)  # TxPowerEnum
# The app accepts 1..100 in units of 100 ms (TlmFragment, IBeaconFragment).
INTERVAL_MIN_MS, INTERVAL_MAX_MS = 100, 10_000
NAME_MAX = 20

_UUID = re.compile(r"^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$")


class ProtocolError(Exception):
    pass


class Refused(Exception):
    """A write this tool will not send."""


# --- unlock -----------------------------------------------------------------

def unlock_key(password: str) -> bytes:
    raw = password.encode("ascii")
    if not 1 <= len(raw) <= 16:
        raise ValueError("password must be 1-16 ASCII characters")
    return raw + b"\xff" * (16 - len(raw))


def unlock_response(password: str, challenge: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    if len(challenge) != 16:
        raise ValueError(f"challenge must be 16 bytes, got {len(challenge)}")
    e = Cipher(algorithms.AES(unlock_key(password)), modes.ECB()).encryptor()
    return e.update(challenge) + e.finalize()


# --- command channel --------------------------------------------------------

def param_get(key: int) -> bytes:
    return bytes([0xEA, key, 0, 0])


def param_set(key: int, value: bytes) -> bytes:
    if key not in SETTABLE_KEYS:
        raise Refused(f"param key 0x{key:02x} is not on the allow-list")
    return bytes([0xEA, key]) + struct.pack(">H", len(value)) + value


@dataclass(frozen=True)
class ParamReply:
    key: int
    value: bytes

    @classmethod
    def parse(cls, data: bytes) -> ParamReply:
        if len(data) < 4 or data[0] != 0xEB:
            raise ProtocolError(f"not a param reply: {data.hex()}")
        n = struct.unpack(">H", data[2:4])[0]
        if len(data) < 4 + n:
            raise ProtocolError(f"short param reply: {data.hex()}")
        return cls(data[1], bytes(data[4:4 + n]))


# --- slots ------------------------------------------------------------------

def frame_name(b: int) -> str:
    return FRAMES.get(b, f"unknown:0x{b:02x}")


def parse_slot_types(data: bytes) -> list[str]:
    return [frame_name(b) for b in data]


def norm_uuid(u: str) -> str:
    if not _UUID.match(u):
        raise ValueError(f"not a UUID: {u!r}")
    h = u.replace("-", "").upper()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def decode_slot_data(data: bytes) -> dict:
    if not data or data[0] == 0xFF:
        return {"frame": "off"}
    kind = frame_name(data[0])
    if kind == "info":
        return {"frame": "info", "name": data[1:].decode("ascii", "replace")}
    if kind == "ibeacon" and len(data) >= 21:
        major, minor = struct.unpack(">HH", data[17:21])
        return {"frame": "ibeacon", "uuid": norm_uuid(data[1:17].hex()), "major": major, "minor": minor}
    if kind == "tlm":
        return {"frame": "tlm"}
    return {"frame": kind, "raw": data[1:].hex()}


def encode_slot_data(slot: dict) -> bytes:
    kind = slot.get("frame")
    if kind == "off":
        return b"\xff"
    if kind == "tlm":
        return b"\x20"
    if kind == "info":
        name = slot.get("name", "")
        if not 1 <= len(name) <= NAME_MAX or not name.isascii() or not name.isprintable():
            raise ValueError(f"device name must be 1-{NAME_MAX} printable ASCII characters: {name!r}")
        return b"\x40" + name.encode("ascii")
    if kind == "ibeacon":
        uuid = bytes.fromhex(norm_uuid(slot["uuid"]).replace("-", ""))
        major, minor = slot["major"], slot["minor"]
        for label, v in (("major", major), ("minor", minor)):
            if not isinstance(v, int) or not 0 <= v <= 0xFFFF:
                raise ValueError(f"{label} must be 0-65535, got {v!r}")
        return b"\x50" + uuid + struct.pack(">HH", major, minor)
    raise ValueError(f"frame {kind!r} is not supported for writing")


# --- per-slot numbers -------------------------------------------------------

def decode_interval(data: bytes) -> int:
    return struct.unpack(">H", data[:2])[0]


def encode_interval(ms: int) -> bytes:
    if not INTERVAL_MIN_MS <= ms <= INTERVAL_MAX_MS or ms % 100:
        raise ValueError(f"interval must be a multiple of 100 in "
                         f"{INTERVAL_MIN_MS}-{INTERVAL_MAX_MS} ms, got {ms}")
    return struct.pack(">H", ms)


def decode_s8(data: bytes) -> int:
    return struct.unpack(">b", data[:1])[0]


def encode_s8(v: int) -> bytes:
    if not -128 <= v <= 127:
        raise ValueError(f"{v} does not fit in a signed byte")
    return struct.pack(">b", v)


def encode_radio_tx(dbm: int) -> bytes:
    if dbm not in RADIO_TX_STEPS:
        raise ValueError(f"radio tx must be one of {RADIO_TX_STEPS} dBm, got {dbm}")
    return encode_s8(dbm)


def decode_battery(data: bytes) -> int:
    return struct.unpack(">H", data[:2])[0]


def decode_trigger(value: bytes) -> dict:
    if not value or value[0] == 0:
        return {"type": "none"}
    return {"type": TRIGGERS.get(value[0], f"unknown:{value[0]}"), "raw": value[1:].hex()}


def encode_trigger(trig: dict) -> bytes:
    # Only "no trigger" (always advertise) is writable: the fleet profile wants
    # every slot advertising unconditionally. Other trigger types read back fine.
    if trig.get("type") != "none":
        raise ValueError("only trigger type 'none' can be written")
    return b"\x00"


def decode_button_power(value: bytes) -> bool:
    """True when a long button press may power the tag off."""
    return bool(value) and value[0] == 1


def encode_button_power(enabled: bool) -> bytes:
    return b"\x01" if enabled else b"\x00"


def colon_mac(mac: str) -> str:
    h = mac.replace(":", "").replace("-", "").upper()
    if not re.fullmatch(r"[0-9A-F]{12}", h):
        raise ValueError(f"not a MAC: {mac!r}")
    return ":".join(h[i:i + 2] for i in range(0, 12, 2))


def bare_mac(mac: str) -> str:
    return colon_mac(mac).replace(":", "")
