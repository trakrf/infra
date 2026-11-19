import json

import pytest

from moko import ble, cli
from test_device import FakeTag

SECRET = "s3cret!pw"


class FakeSession:
    tags: dict = {}

    def __init__(self, proxy, mac, password, scan_seconds):
        from moko import protocol as p

        self.mac = p.colon_mac(mac)
        self.rssi = -50
        self.password = password

    async def __aenter__(self):
        tag = self.tags.get(self.mac)
        if tag is None:
            raise ble.DeviceNotFound(f"{self.mac} is not advertising")
        if self.password != SECRET:
            raise ble.AuthFailed(f"{self.mac} stayed locked")
        tag.mac, tag.rssi = self.mac, self.rssi
        return tag

    async def __aexit__(self, *exc):
        return None


@pytest.fixture
def env(monkeypatch, tmp_path):
    monkeypatch.setenv("ESPHOME_PROXY_HOST", "proxy.invalid")
    monkeypatch.setenv("NOTIFY_BLE_PASSWORD", SECRET)
    monkeypatch.setenv("BLE_MCP_RADIO_LOCK", str(tmp_path / "radio.lock"))
    monkeypatch.delenv("BLE_MCP_RADIO_HELD", raising=False)
    monkeypatch.setattr(ble, "Session", FakeSession)
    FakeSession.tags = {}
    return tmp_path


def fake_tag(mac):
    t = FakeTag()
    t.mac = mac

    async def param(frame, _orig=t.param):
        if frame[1] == 0x20:
            from moko import protocol as p
            return p.ParamReply(0x20, bytes.fromhex(p.bare_mac(t.mac)))
        return await _orig(frame)

    t.param = param
    return t


def test_read_prints_json_and_never_the_password(env, capsys):
    FakeSession.tags = {"CF:FB:F5:81:6B:C9": fake_tag("CF:FB:F5:81:6B:C9")}
    assert cli.main(["read", "--mac", "cffbf5816bc9"]) == 0
    out, err = capsys.readouterr()
    assert json.loads(out)["battery_mv"] == 3141
    assert SECRET not in out + err


def test_apply_then_rerun_is_no_op(env, capsys):
    FakeSession.tags = {"F5:DD:87:90:E8:4F": fake_tag("F5:DD:87:90:E8:4F")}
    assert cli.main(["apply", "--mac", "F5DD8790E84F", "--minor", "1002", "--name", "Bob"]) == 0
    assert "written, read back OK" in capsys.readouterr().err
    assert cli.main(["apply", "--mac", "F5DD8790E84F", "--minor", "1002", "--name", "Bob"]) == 0
    err = capsys.readouterr().err
    assert "no-op" in err and "  0  " in err


def test_apply_needs_a_minor_before_touching_the_radio(env, capsys):
    assert cli.main(["apply", "--mac", "F5DD8790E84F"]) == cli.EXIT_USAGE
    assert "minor" in capsys.readouterr().err


def test_batch_summarises_and_fails_if_any_tag_fails(env, capsys, tmp_path):
    FakeSession.tags = {"F5:DD:87:90:E8:4F": fake_tag("F5:DD:87:90:E8:4F"),
                        "D7:48:FB:BD:99:D4": fake_tag("D7:48:FB:BD:99:D4")}
    f = tmp_path / "tags.csv"
    f.write_text("F5DD8790E84F,1002,Bob\nD748FBBD99D4,1003,Charlie\nDC90BC628FF4,1004,Dave\n")
    assert cli.main(["batch", "--file", str(f)]) == cli.EXIT_FAIL
    err = capsys.readouterr().err
    table = err[err.index("MAC "):]
    assert "F5:DD:87:90:E8:4F   1002  PASS" in table
    assert "D7:48:FB:BD:99:D4   1003  PASS" in table
    assert "DC:90:BC:62:8F:F4   1004  FAIL" in table and "not advertising" in table


class RefusingSession(FakeSession):
    """A device that advertises but refuses the GATT connection (seen live, 2026-11-18)."""

    async def __aenter__(self):
        from bleak.exc import BleakError

        raise BleakError("Error ESP_GATT_ERROR while connecting: Connection failed due to GATT operation error")


def test_connection_error_is_a_fail_not_a_crash(env, capsys, monkeypatch, tmp_path):
    monkeypatch.setattr(ble, "Session", RefusingSession)
    assert cli.main(["read", "--mac", "0C66EB17F521"]) == cli.EXIT_FAIL
    assert "ESP_GATT_ERROR" in capsys.readouterr().err
    f = tmp_path / "tags.csv"
    f.write_text("0C66EB17F521,1\nF5DD8790E84F,2\n")
    assert cli.main(["batch", "--file", str(f)]) == cli.EXIT_FAIL
    table = capsys.readouterr().err
    assert "0C:66:EB:17:F5:21      1  FAIL" in table
    assert "F5:DD:87:90:E8:4F      2  FAIL" in table  # the batch kept going


def test_wrong_password_is_a_fail_not_a_crash(env, capsys, monkeypatch):
    monkeypatch.setenv("NOTIFY_BLE_PASSWORD", "wrong")
    FakeSession.tags = {"F5:DD:87:90:E8:4F": fake_tag("F5:DD:87:90:E8:4F")}
    assert cli.main(["apply", "--mac", "F5DD8790E84F", "--minor", "1"]) == cli.EXIT_FAIL
    assert "stayed locked" in capsys.readouterr().err


def test_dry_run_writes_nothing(env, capsys):
    tag = fake_tag("F5:DD:87:90:E8:4F")
    FakeSession.tags = {"F5:DD:87:90:E8:4F": tag}
    assert cli.main(["apply", "--mac", "F5DD8790E84F", "--minor", "1", "--dry-run"]) == 0
    assert tag.slots[0]["data"] == bytes.fromhex("404e6f74696679")
    assert "would write slot 0 data" in capsys.readouterr().err


def test_password_file(env, capsys, tmp_path, monkeypatch):
    monkeypatch.delenv("NOTIFY_BLE_PASSWORD")
    pw = tmp_path / "pw"
    pw.write_text(SECRET + "\n")
    FakeSession.tags = {"CF:FB:F5:81:6B:C9": fake_tag("CF:FB:F5:81:6B:C9")}
    assert cli.main(["read", "--mac", "CFFBF5816BC9", "--password-file", str(pw)]) == 0


def test_radio_busy(env, capsys):
    import fcntl
    import os

    fd = os.open(os.environ["BLE_MCP_RADIO_LOCK"], os.O_WRONLY | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        assert cli.main(["read", "--mac", "CFFBF5816BC9"]) == cli.EXIT_BUSY
    finally:
        os.close(fd)
