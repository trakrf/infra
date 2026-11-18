import asyncio

import pytest

from gls10 import cli, plan
from gls10 import protocol as p

MAC = "C4:DE:E2:29:A1:76"
CID = "C4DEE229A176"
URI = "mqtts://u:pw@h:8883"
URL = "http://10.0.0.5:1/t/"


def ok(*fields):
    return p.Reply(cmd=0, body=b"\x00\n" + "".join(f + "\n" for f in fields).encode(), crc_ok=True)


class FakeUnit:
    """Answers like a GL-S10: it stores what is written and returns it on read."""

    def __init__(self, refuse=(), corrupt_topics=False):
        self.mac = MAC
        self.sent = []
        self.refuse = set(refuse)
        self.corrupt_topics = corrupt_topics
        self.cfg = {p.GET_BROKER: ["mqtt://:@127.0.0.1:1883"], p.GET_CLIENT_ID: [CID],
                    p.GET_TOPICS: ["GL-IoT/comTopic/x", "GL-IoT/dataTopic/x", "GL-IoT/rspTopic/x"]}

    async def cmd(self, cmd, data=b"", wait=6.0):
        self.sent.append(cmd)
        if cmd in self.refuse:
            return p.Reply(cmd=cmd, body=b"\x01\n", crc_ok=True)
        if cmd == p.DEVICE_INFO:
            return ok(MAC, "C4:DE:E2:29:A1:74", "serial", "name", "3.0.3", "\x00")
        if cmd in self.cfg:
            return ok(*self.cfg[cmd])
        fields = data.decode().split("\n")[:-1]
        if cmd == p.SET_BROKER:
            self.cfg[p.GET_BROKER] = fields
        elif cmd == p.SET_CLIENT_ID:
            self.cfg[p.GET_CLIENT_ID] = fields
        elif cmd == p.SET_TOPICS:
            self.cfg[p.GET_TOPICS] = fields[:2] if self.corrupt_topics else fields
        elif cmd == p.REBOOT:
            return None  # unit drops BLE
        return ok()


class FakeServer:
    def __init__(self, fetched=True):
        self.fetched = {"ca.crt", "client.crt", "client.key"} if fetched else set()

    def wait_all(self, timeout):
        return len(self.fetched) == 3


_DEFAULT = object()


def run(unit, steps, expected, server=_DEFAULT):
    lines = []
    srv = FakeServer() if server is _DEFAULT else server
    t0 = asyncio.run(cli.configure(unit, steps, expected, srv, 0, lines.append))
    return t0, lines


READS = [p.DEVICE_INFO, p.GET_BROKER, p.GET_CLIENT_ID, p.GET_TOPICS]


def test_provision_sends_the_documented_sequence():
    unit = FakeUnit()
    run(unit, plan.provision(URI, CID, "trakrf.id", URL),
        plan.expected_config(URI, CID, "trakrf.id"))
    assert unit.sent == READS + [p.SET_BROKER, p.SET_CLIENT_ID, p.SET_TOPICS, p.CERT_URL] \
        + READS + [p.REBOOT]


def test_recert_writes_only_the_cert_url_then_reboots():
    unit = FakeUnit()
    run(unit, plan.recert(URL), {})
    assert unit.sent == READS + [p.CERT_URL, p.REBOOT]


def test_a_refused_write_aborts_before_reboot():
    unit = FakeUnit(refuse={p.SET_TOPICS})
    with pytest.raises(cli.Fail, match="topics"):
        run(unit, plan.provision(URI, CID, "trakrf.id", URL), {})
    assert p.REBOOT not in unit.sent and p.CERT_URL not in unit.sent


def test_a_readback_mismatch_aborts_before_reboot():
    unit = FakeUnit(corrupt_topics=True)
    with pytest.raises(cli.Fail, match="read-back mismatch: topics"):
        run(unit, plan.provision(URI, CID, "trakrf.id", URL),
            plan.expected_config(URI, CID, "trakrf.id"))
    assert p.REBOOT not in unit.sent


def test_the_wrong_unit_is_refused_before_any_write():
    unit = FakeUnit()
    unit.mac = "0C:B8:15:1E:68:3A"
    with pytest.raises(cli.Fail, match="expected"):
        run(unit, plan.recert(URL), {})
    assert unit.sent == [p.DEVICE_INFO]


def test_secret_payloads_are_never_echoed():
    unit = FakeUnit()
    _, lines = run(unit, plan.wifi_join(URI, CID, "trakrf.id", ("ssid", "wifi-pw")),
                   plan.expected_config(URI, CID, "trakrf.id"), server=None)
    written = "\n".join(lines)
    assert "wifi-pw" not in written
    assert "0x07 broker <secret>: OK" in written


def test_wifi_pass1_writes_mqtt_and_wifi_then_reboots_without_cert():
    unit = FakeUnit()
    run(unit, plan.wifi_join(URI, CID, "trakrf.id", ("ssid", "pw")),
        plan.expected_config(URI, CID, "trakrf.id"), server=None)
    assert unit.sent == READS + [p.SET_BROKER, p.SET_CLIENT_ID, p.SET_TOPICS,
                                 p.WIFI_CONNECT] + READS + [p.REBOOT]


def test_unfetched_certs_still_reboot_and_say_so():
    unit = FakeUnit()
    _, lines = run(unit, plan.recert(URL), {}, FakeServer(fetched=False))
    assert unit.sent[-1] == p.REBOOT
    assert any("not yet fetched" in ln for ln in lines)


def test_missing_proxy_host_is_a_usage_error(monkeypatch, capsys):
    monkeypatch.delenv("ESPHOME_PROXY_HOST", raising=False)
    assert cli.main(["info", "--mac", MAC]) == cli.EXIT_USAGE


def test_provision_with_ssid_stops_after_pass_1_and_names_the_next_command(
        monkeypatch, tmp_path, capsys):
    from gls10 import creds as creds_mod

    monkeypatch.setenv("ESPHOME_PROXY_HOST", "127.0.0.1")
    monkeypatch.setenv("WIFI_PASS", "wifi-pw")
    monkeypatch.setenv("BLE_MCP_RADIO_LOCK", str(tmp_path / "radio.lock"))
    monkeypatch.setattr(cli.creds, "broker_creds",
                        lambda env: creds_mod.BrokerCreds("u", "broker-pw", "h"))
    sent = []

    async def fake_ble(sess, steps, expected, server, fetch_timeout, say):
        sent.extend(s.cmd for s in steps)
        assert server is None
        return 0.0

    monkeypatch.setattr(cli, "_ble", fake_ble)
    code = cli.main(["provision", "--mac", MAC, "--env", "preview", "--ssid", "myssid"])
    out = capsys.readouterr().out
    assert code == cli.EXIT_NEXT_PASS
    assert p.CERT_URL not in sent and p.WIFI_CONNECT in sent
    assert f"gls10 recert --mac {MAC} --env preview" in out
    assert "wifi-pw" not in out and "broker-pw" not in out


def test_cert_url_status_01_is_not_fatal_the_downloads_decide():
    # Hardware: 0CB8151E683A answered 0x1a with status 01 and still GET all three files.
    unit = FakeUnit(refuse={p.CERT_URL})
    _, lines = run(unit, plan.recert(URL), {})
    assert unit.sent == READS + [p.CERT_URL, p.REBOOT]
    assert any("not decisive" in ln for ln in lines)


def test_cert_url_with_no_reply_is_still_fatal():
    class Silent(FakeUnit):
        async def cmd(self, cmd, data=b"", wait=6.0):
            if cmd == p.CERT_URL:
                self.sent.append(cmd)
                return None
            return await super().cmd(cmd, data, wait)

    unit = Silent()
    with pytest.raises(cli.Fail, match="no reply"):
        run(unit, plan.recert(URL), {})
    assert p.REBOOT not in unit.sent


def test_cert_url_status_01_with_no_downloads_ends_in_fail_path():
    unit = FakeUnit(refuse={p.CERT_URL})
    _, lines = run(unit, plan.recert(URL), {}, FakeServer(fetched=False))
    assert any("not yet fetched" in ln for ln in lines)
