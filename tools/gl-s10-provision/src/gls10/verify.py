"""Broker-side proof that a unit came up: PASS needs both

  1. the broker logging `New client connected ... as <client id>` after the
     reboot was sent (the unit's TLS + auth worked), and
  2. at least one message on `<topic base>/<client id>/reads` (it is publishing).

A message alone is not enough: the shared user's ACL lets anyone publish there.
"""

from __future__ import annotations

import re
import secrets
import ssl
import subprocess
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from gls10.creds import PORT, BrokerCreds

_CONNECT = re.compile(r"^(\d+): New client connected from (\S+) as (\S+) ")


@dataclass(frozen=True)
class Connect:
    at: int
    peer: str


@dataclass(frozen=True)
class Result:
    connect: Connect | None
    reads: int

    @property
    def passed(self) -> bool:
        return self.connect is not None and self.reads > 0


def find_connect(log: str, cid: str, since: int) -> Connect | None:
    for line in log.splitlines():
        m = _CONNECT.match(line)
        if m and m.group(3) == cid and int(m.group(1)) >= since:
            return Connect(at=int(m.group(1)), peer=m.group(2))
    return None


def broker_log(env: str, since: int) -> str:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(since - 5))
    return subprocess.run(
        ["kubectl", "-n", f"trakrf-{env}", "logs", "deploy/trakrf-mosquitto",
         "-c", "mosquitto", f"--since-time={stamp}"],
        check=True, capture_output=True, text=True,
    ).stdout


class ReadsWatcher:
    """Subscribe to the unit's reads topic over TLS 1.2 as a distinct client id."""

    def __init__(self, creds: BrokerCreds, topic: str):
        import paho.mqtt.client as mqtt

        self.arrivals: list[float] = []  # epoch seconds
        self.error: str | None = None
        self._lock = threading.Lock()
        self._c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                              client_id=f"gls10-verify-{secrets.token_hex(3)}")
        self._c.username_pw_set(creds.username, creds.password)
        self._c.tls_set(tls_version=ssl.PROTOCOL_TLSv1_2)

        def on_connect(client, _ud, _flags, rc, _props):
            if rc.is_failure:
                self.error = f"verifier could not connect: {rc}"
            else:
                client.subscribe(topic, qos=0)

        def on_message(_client, _ud, _msg):
            with self._lock:
                self.arrivals.append(time.time())

        self._c.on_connect = on_connect
        self._c.on_message = on_message
        self._host = creds.host

    def reads_since(self, t: float) -> int:
        with self._lock:
            return sum(1 for a in self.arrivals if a >= t)

    def __enter__(self) -> ReadsWatcher:
        self._c.connect(self._host, PORT, keepalive=60)
        self._c.loop_start()
        return self

    def __exit__(self, *exc) -> None:
        self._c.disconnect()
        self._c.loop_stop()


def wait_for_unit(env: str, cid: str, since: int, watcher: ReadsWatcher, timeout: float,
                  say: Callable[[str], None], poll: float = 5.0) -> Result:
    """Poll until the unit has connected since `since` and published after connecting."""
    deadline = time.monotonic() + timeout
    connect: Connect | None = None
    while True:
        if connect is None:
            connect = find_connect(broker_log(env, since), cid, since)
            if connect:
                say(f"  broker: {cid} connected from {connect.peer} "
                    f"(+{connect.at - since}s after reboot)")
        # Log stamps are whole seconds; allow one second of skew.
        reads = watcher.reads_since(connect.at - 1) if connect else 0
        if (connect and reads) or time.monotonic() >= deadline or watcher.error:
            return Result(connect=connect, reads=reads)
        time.sleep(poll)
