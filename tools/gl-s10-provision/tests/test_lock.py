import fcntl
import os
import subprocess

import pytest

from gls10 import lock


@pytest.fixture
def path(tmp_path, monkeypatch):
    monkeypatch.delenv("BLE_MCP_RADIO_HELD", raising=False)
    return str(tmp_path / "radio.lock")


def test_acquires_and_releases(path):
    with lock.radio_lock("t", path=path):
        assert os.environ["BLE_MCP_RADIO_HELD"] == f"{os.getpid()}:{path}"
    assert "BLE_MCP_RADIO_HELD" not in os.environ
    with lock.radio_lock("t", path=path):  # released, so re-acquirable
        pass


def test_refuses_when_someone_else_holds_it(path):
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        with pytest.raises(lock.RadioBusy):
            with lock.radio_lock("t", path=path):
                pytest.fail("ran while the radio was held")
    finally:
        os.close(fd)


def test_passes_through_inside_an_ancestor_hold(path, monkeypatch):
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX)  # held by "us" as if by a wrapping ble-radio-lock
    monkeypatch.setenv("BLE_MCP_RADIO_HELD", f"{os.getpid()}:{path}")
    try:
        with lock.radio_lock("t", path=path):
            pass
    finally:
        os.close(fd)


def test_a_marker_naming_a_non_ancestor_buys_nothing(path, monkeypatch):
    other = subprocess.Popen(["sleep", "30"])
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX)
    monkeypatch.setenv("BLE_MCP_RADIO_HELD", f"{other.pid}:{path}")
    try:
        with pytest.raises(lock.RadioBusy):
            with lock.radio_lock("t", path=path):
                pass
    finally:
        os.close(fd)
        other.kill()
        other.wait()


def test_a_marker_for_another_path_buys_nothing(path, monkeypatch, tmp_path):
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX)
    monkeypatch.setenv("BLE_MCP_RADIO_HELD", f"{os.getpid()}:{tmp_path}/other.lock")
    try:
        with pytest.raises(lock.RadioBusy):
            with lock.radio_lock("t", path=path):
                pass
    finally:
        os.close(fd)


def test_default_path_is_the_shared_literal(monkeypatch):
    monkeypatch.delenv("BLE_MCP_RADIO_LOCK", raising=False)
    assert lock.lock_path() == "/tmp/ble-mcp-test.radio.lock"
    monkeypatch.setenv("BLE_MCP_RADIO_LOCK", "/x/y.lock")
    assert lock.lock_path() == "/x/y.lock"
