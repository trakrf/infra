"""Hold the shared BLE radio for a whole run.

The ESPHome proxy's radio is shared with other sessions (ble-mcp-test and
friends). The contract they agree on is flock(2) on one fixed path -- the same
one ble-mcp-test's `bin/ble-radio-lock` takes -- so this participates directly
rather than requiring that checkout. Same rules as that script:

  * acquire-or-refuse; there is no "is it free?" query,
  * hold for the whole run, released by the kernel if we die,
  * pass through only when BLE_MCP_RADIO_HELD names a LIVE ANCESTOR holding the
    SAME path (so wrapping a run in `ble-radio-lock -- ...` also works).
"""

from __future__ import annotations

import contextlib
import fcntl
import os
import socket
import tempfile
import time
from collections.abc import Iterator

DEFAULT_LOCK_PATH = "/tmp/ble-mcp-test.radio.lock"
HELD_ENV = "BLE_MCP_RADIO_HELD"


class RadioBusy(Exception):
    pass


def lock_path() -> str:
    return os.environ.get("BLE_MCP_RADIO_LOCK", DEFAULT_LOCK_PATH)


def _ppid(pid: int) -> int | None:
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("PPid:"):
                    return int(line.split()[1])
    except OSError:
        return None
    return None


def _is_ancestor(target: int) -> bool:
    pid: int | None = os.getpid()
    for _ in range(64):
        if pid == target:
            return True
        if pid in (None, 0, 1):
            return False
        pid = _ppid(pid)
    return False


def _inside_ancestor_hold(path: str) -> bool:
    held = os.environ.get(HELD_ENV, "")
    pid_s, _, held_path = held.partition(":")
    if not pid_s.isdigit() or held_path != path:
        return False
    pid = int(pid_s)
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return _is_ancestor(pid)


def _holder_text(path: str) -> str:
    try:
        with open(path + ".holder") as f:
            return f.read().strip()
    except OSError:
        return "holder: unidentified"


def _record_holder(path: str, label: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".holder.",
                               dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w") as f:
        f.write(f"pid={os.getpid()}\nhost={socket.gethostname()}\nlabel={label}\n"
                f"command=gls10\nsince={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n"
                f"since_epoch={int(time.time())}\n")
    os.replace(tmp, path + ".holder")


@contextlib.contextmanager
def radio_lock(label: str, path: str | None = None) -> Iterator[None]:
    path = path or lock_path()
    if _inside_ancestor_hold(path):
        yield
        return
    # Append, never truncate, never unlink: another process may hold this inode.
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o666)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RadioBusy(f"radio busy ({path}); nothing was sent.\n"
                            f"{_holder_text(path)}") from None
        _record_holder(path, label)
        prev = os.environ.get(HELD_ENV)
        os.environ[HELD_ENV] = f"{os.getpid()}:{path}"
        try:
            yield
        finally:
            if prev is None:
                os.environ.pop(HELD_ENV, None)
            else:
                os.environ[HELD_ENV] = prev
    finally:
        os.close(fd)
