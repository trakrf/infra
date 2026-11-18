"""Broker credentials, read from the cluster at run time and never displayed."""

from __future__ import annotations

import base64
import json
import re
import subprocess
from collections.abc import Callable
from dataclasses import dataclass, field

ENVS = ("preview", "prod")
SECRET = "trakrf-mosquitto-auth"
PORT = 8883


def broker_host(env: str) -> str:
    if env not in ENVS:
        raise ValueError(f"env must be one of {ENVS}, not {env!r}")
    return f"mqtt.{env}.gke.trakrf.id"


@dataclass(frozen=True)
class BrokerCreds:
    username: str
    password: str = field(repr=False)
    host: str

    @property
    def uri(self) -> str:
        return f"mqtts://{self.username}:{self.password}@{self.host}:{PORT}"

    def __str__(self) -> str:
        return f"mqtts://{self.username}:<MASKED>@{self.host}:{PORT}"


def _kubectl(argv: list[str]) -> str:
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


def broker_creds(env: str, runner: Callable[[list[str]], str] = _kubectl) -> BrokerCreds:
    host = broker_host(env)
    raw = runner(["kubectl", "-n", f"trakrf-{env}", "get", "secret", SECRET, "-o", "json"])
    data = json.loads(raw)["data"]
    dec = lambda k: base64.b64decode(data[k]).decode()  # noqa: E731
    return BrokerCreds(dec("username"), dec("password"), host)


class Masker:
    """Replace every registered secret in a string. Applied to all device output."""

    def __init__(self) -> None:
        self._secrets: list[str] = []

    def add(self, secret: str) -> None:
        if secret:
            self._secrets.append(secret)
            self._secrets.sort(key=len, reverse=True)

    def __call__(self, text: str) -> str:
        for s in self._secrets:
            text = text.replace(s, "<MASKED>")
        # A broker URI read back from a unit may carry a password we never loaded.
        return _URI_PASSWORD.sub(r"\1<MASKED>@", text)


_URI_PASSWORD = re.compile(r"(://[^:/@\s]*:)[^@\s]+@")
