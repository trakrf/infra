"""What gets written to a unit, and in what order. Pure: no radio, no network.

Provision: broker, client id, topics, cert URL, then optional Wi-Fi. Re-cert:
the cert URL only. The reboot (0x22) that ends config mode is not a plan step;
the CLI sends it once the cert fetch is accounted for.
"""

from __future__ import annotations

from dataclasses import dataclass

from gls10 import protocol as p


@dataclass(frozen=True)
class Step:
    label: str
    cmd: int
    data: bytes
    secret: bool = False  # never echo the payload
    wait: float = 6.0


def cert_step(base_url: str) -> Step:
    return Step("cert URL", p.CERT_URL, p.cert_url_payload(base_url), wait=10.0)


def provision(uri: str, cid: str, topic_base: str, cert_url: str,
              wifi: tuple[str, str] | None) -> list[Step]:
    steps = [
        Step("broker", p.SET_BROKER, p.broker_payload(uri), secret=True),
        Step("client id", p.SET_CLIENT_ID, p.client_id_payload(cid)),
        Step("topics", p.SET_TOPICS, p.topics_payload(topic_base, cid)),
        cert_step(cert_url),
    ]
    if wifi:
        steps.append(Step("Wi-Fi", p.WIFI_CONNECT, p.wifi_payload(*wifi), secret=True, wait=10.0))
    return steps


def recert(cert_url: str) -> list[Step]:
    return [cert_step(cert_url)]


def expected_config(uri: str, cid: str, topic_base: str) -> dict[int, list[str]]:
    """Read-back command -> the fields a correctly written unit returns."""
    return {
        p.GET_BROKER: [uri],
        p.GET_CLIENT_ID: [cid],
        p.GET_TOPICS: p.topics(topic_base, cid),
    }
