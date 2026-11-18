import base64
import json

import pytest

from gls10 import creds, plan
from gls10 import protocol as p


def _secret(user, pw):
    enc = lambda s: base64.b64encode(s.encode()).decode()  # noqa: E731
    return json.dumps({"data": {"username": enc(user), "password": enc(pw), "passwd": enc("x")}})


def test_broker_creds_come_from_the_env_namespace_secret():
    calls = []

    def runner(argv):
        calls.append(argv)
        return _secret("trakrf-mqtt", "s3cr3t/pw")

    c = creds.broker_creds("preview", runner=runner)
    assert calls == [["kubectl", "-n", "trakrf-preview", "get", "secret",
                      "trakrf-mosquitto-auth", "-o", "json"]]
    assert (c.username, c.password, c.host) == ("trakrf-mqtt", "s3cr3t/pw",
                                                "mqtt.preview.gke.trakrf.id")
    assert c.uri == "mqtts://trakrf-mqtt:s3cr3t/pw@mqtt.preview.gke.trakrf.id:8883"


def test_creds_repr_never_shows_the_password():
    c = creds.BrokerCreds("u", "hunter2", "h")
    assert "hunter2" not in repr(c) and "hunter2" not in str(c)


@pytest.mark.parametrize("env", ["dev", "trakrf-preview", ""])
def test_unknown_env_is_refused(env):
    with pytest.raises(ValueError):
        creds.broker_creds(env, runner=lambda a: "")


def test_masker_redacts_every_registered_secret_anywhere():
    m = creds.Masker()
    m.add("hunter2")
    m.add("wifi pass")
    m.add("")
    s = m("mqtts://u:hunter2@h:8883 and 'wifi pass' and \\x00hunter2")
    assert "hunter2" not in s and "wifi pass" not in s
    assert s.count("<MASKED>") == 3


def test_masker_redacts_a_uri_password_it_was_never_told_about():
    s = creds.Masker()("0x08 broker: mqtts://trakrf-mqtt:unknown-pw@h:8883")
    assert "unknown-pw" not in s and "trakrf-mqtt:<MASKED>@h" in s
    assert creds.Masker()("mqtt://:@127.0.0.1:1883") == "mqtt://:@127.0.0.1:1883"


def test_provision_is_mqtt_then_cert():
    steps = plan.provision("mqtts://u:p@h:8883", "C4DEE229A176", "trakrf.id",
                           "http://10.0.0.5:1/t/")
    assert [s.cmd for s in steps] == [p.SET_BROKER, p.SET_CLIENT_ID, p.SET_TOPICS, p.CERT_URL]
    assert steps[0].secret and not steps[1].secret


def test_wifi_join_is_mqtt_then_wifi_and_no_cert():
    # Hardware: in config mode the unit saves the SSID but does not join it, and
    # refuses 0x1a (status 01) with no network. Certs come in pass 2 (recert).
    steps = plan.wifi_join("mqtts://u:p@h:8883", "C4DEE229A176", "trakrf.id", ("ssid", "pw"))
    assert [s.cmd for s in steps] == [p.SET_BROKER, p.SET_CLIENT_ID, p.SET_TOPICS,
                                      p.WIFI_CONNECT]
    assert steps[-1].secret


def test_recert_is_the_cert_step_only():
    assert [s.cmd for s in plan.recert("http://10.0.0.5:1/t/")] == [p.CERT_URL]


def test_expected_readback_matches_what_was_written():
    exp = plan.expected_config("mqtts://u:p@h:8883", "C4DEE229A176", "trakrf.id")
    assert exp == {
        p.GET_BROKER: ["mqtts://u:p@h:8883"],
        p.GET_CLIENT_ID: ["C4DEE229A176"],
        p.GET_TOPICS: ["trakrf.id/C4DEE229A176/cmds", "trakrf.id/C4DEE229A176/reads",
                       "trakrf.id/C4DEE229A176/resps"],
    }


def test_no_plan_ever_contains_a_forbidden_command():
    steps = (plan.provision("mqtts://u:p@h:8883", "C4DEE229A176", "trakrf.id", "http://x/t/")
             + plan.wifi_join("mqtts://u:p@h:8883", "C4DEE229A176", "trakrf.id", ("s", "p"))
             + plan.recert("http://x/t/"))
    assert not {s.cmd for s in steps} & p.FORBIDDEN
