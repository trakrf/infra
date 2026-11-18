"""Check what a tag actually advertises, as the GL-S10 gateways report it.

Gateways publish JSON on `<topic base>/<gateway>/reads` with a `dev_list` of
sightings: {mac, rssi, ts (ms), ad (raw advertising data, hex)}. This module
classifies each sighting of one tag into a frame, then judges the frames
against the tag's desired state. Pure, apart from `Watcher`.

Intervals are measured per gateway and the best-sampled gateway wins: a
gateway's scan duty cycle drops packets, so an observed interval is an upper
bound on the real one, and mixing gateways would invent short gaps.
"""

from __future__ import annotations

import json
import secrets
import ssl
import statistics
import struct
import threading
from dataclasses import dataclass, field

BATTERY_MV = (2000, 3700)  # plausible for a CR2032/CR2477 cell


@dataclass(frozen=True)
class Frame:
    kind: str  # ibeacon | info | tlm | other
    gateway: str
    ts_ms: int
    battery_mv: int | None = None
    ibeacon: tuple[str, int, int] | None = None


def ad_structures(hexstr: str):
    raw = bytes.fromhex(hexstr)
    i = 0
    while i < len(raw):
        n = raw[i]
        if n == 0 or i + 1 + n > len(raw):
            return
        yield raw[i + 1], raw[i + 2:i + 1 + n]
        i += 1 + n


def classify(ad: str, gateway: str, ts_ms: int) -> Frame:
    try:
        structs = list(ad_structures(ad))
    except ValueError:
        return Frame("other", gateway, ts_ms)
    for t, d in structs:
        if t == 0xFF and d[:4] == b"\x4c\x00\x02\x15" and len(d) >= 24:
            u = d[4:20].hex().upper()
            uuid = f"{u[:8]}-{u[8:12]}-{u[12:16]}-{u[16:20]}-{u[20:]}"
            major, minor = struct.unpack(">HH", d[20:24])
            return Frame("ibeacon", gateway, ts_ms, ibeacon=(uuid, major, minor))
        if t == 0x16 and d[:3] == b"\xaa\xfe\x20" and len(d) >= 6:
            # Eddystone-TLM: AA FE | 20 | version | battery mV BE | temp | count | uptime
            return Frame("tlm", gateway, ts_ms, battery_mv=struct.unpack(">H", d[4:6])[0])
        if t == 0x16 and d[:3] == b"\xab\xfe\x40" and len(d) >= 7:
            # Moko device info: 40 | ? | ? | battery mV BE (offset 3-4 from 0x40)
            return Frame("info", gateway, ts_ms, battery_mv=struct.unpack(">H", d[5:7])[0])
    return Frame("other", gateway, ts_ms)


def frames_from_message(topic: str, payload: bytes, mac: str) -> list[Frame]:
    gateway = topic.split("/")[1] if topic.count("/") >= 2 else topic
    try:
        msg = json.loads(payload)
    except (ValueError, UnicodeDecodeError):
        return []
    out = []
    for e in msg.get("dev_list") or []:
        if str(e.get("mac", "")).upper() == mac and e.get("ad"):
            out.append(classify(e["ad"], gateway, int(e.get("ts", 0))))
    return out


def observed_interval_ms(frames: list[Frame]) -> int | None:
    """Median gap on the gateway that saw this frame kind most often."""
    by_gw: dict[str, list[int]] = {}
    for f in frames:
        by_gw.setdefault(f.gateway, []).append(f.ts_ms)
    best = max(by_gw.values(), key=len, default=[])
    ts = sorted(set(best))
    gaps = [b - a for a, b in zip(ts, ts[1:]) if b > a]
    return int(statistics.median(gaps)) if gaps else None


@dataclass
class Report:
    seen: dict[str, int] = field(default_factory=dict)
    intervals: dict[str, int | None] = field(default_factory=dict)
    battery_mv: int | None = None
    problems: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not self.problems


def judge(frames: list[Frame], want: dict, window_s: float) -> Report:
    """Compare sightings with the desired state's live slots."""
    rep = Report()
    for f in frames:
        rep.seen[f.kind] = rep.seen.get(f.kind, 0) + 1
    live = [s for s in want["slots"] if s["frame"] != "off"]
    for s in live:
        kind = s["frame"]
        fs = [f for f in frames if f.kind == kind]
        if not fs:
            rep.problems.append(f"no {kind} frames in {window_s:.0f}s")
            continue
        iv = observed_interval_ms(fs)
        rep.intervals[kind] = iv
        want_ms = s["interval_ms"]
        if iv is not None and iv < want_ms * 0.5:
            rep.problems.append(f"{kind} every ~{iv} ms, profile says {want_ms} ms")
        if kind == "ibeacon":
            ids = {f.ibeacon for f in fs}
            target = (s["uuid"], s["major"], s["minor"])
            if ids != {target}:
                rep.problems.append(f"iBeacon advertises {sorted(ids)}, profile says {target}")
            if iv is not None and iv > max(want_ms * 5, 5000):
                rep.problems.append(f"iBeacon only every ~{iv} ms, profile says {want_ms} ms")
    batteries = [f.battery_mv for f in frames if f.battery_mv is not None]
    if any(s["frame"] in ("info", "tlm") for s in live):
        if not batteries:
            rep.problems.append("no battery reading decoded")
        else:
            rep.battery_mv = batteries[-1]
            if not BATTERY_MV[0] <= rep.battery_mv <= BATTERY_MV[1]:
                rep.problems.append(f"battery {rep.battery_mv} mV is outside {BATTERY_MV}")
    extra = set(rep.seen) - {s["frame"] for s in live} - {"other"}
    if extra:
        rep.problems.append(f"frames the profile turned off are still on air: {sorted(extra)}")
    return rep


class Watcher:
    """Subscribe to every gateway's reads topic and keep one tag's sightings."""

    def __init__(self, creds, topic_base: str, mac: str):
        import paho.mqtt.client as mqtt

        self.mac = mac
        self.frames: list[Frame] = []
        self.error: str | None = None
        self._lock = threading.Lock()
        self._c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                              client_id=f"moko-verify-{secrets.token_hex(3)}")
        self._c.username_pw_set(creds.username, creds.password)
        self._c.tls_set(tls_version=ssl.PROTOCOL_TLSv1_2)
        topic = f"{topic_base}/+/reads"

        def on_connect(client, _ud, _flags, rc, _props):
            if rc.is_failure:
                self.error = f"verifier could not connect: {rc}"
            else:
                client.subscribe(topic, qos=0)

        def on_message(_client, _ud, msg):
            fs = frames_from_message(msg.topic, msg.payload, self.mac)
            if fs:
                with self._lock:
                    self.frames.extend(fs)

        self._c.on_connect = on_connect
        self._c.on_message = on_message
        self._host, self._port = creds.host, 8883

    def snapshot(self) -> list[Frame]:
        with self._lock:
            return list(self.frames)

    def __enter__(self) -> Watcher:
        self._c.connect(self._host, self._port, keepalive=60)
        self._c.loop_start()
        return self

    def __exit__(self, *exc) -> None:
        self._c.disconnect()
        self._c.loop_stop()
