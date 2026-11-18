"""A BLE session with one BeaconX Pro tag, through an ESPHome Bluetooth proxy.

Nothing here runs unless the caller holds the radio lock (gls10.lock).
The connect sequence follows the BeaconX Pro app: subscribe to the command
channel and the disconnect notifier, read lock state, and unlock if locked.
"""

from __future__ import annotations

import asyncio
from types import TracebackType

from moko import protocol as p


class DeviceNotFound(Exception):
    pass


class AuthFailed(Exception):
    pass


class Session:
    def __init__(self, proxy_host: str, mac: str, password: str, scan_seconds: float = 20.0):
        self.proxy_host = proxy_host
        self.mac = p.colon_mac(mac)
        self._password = password
        self.scan_seconds = scan_seconds
        self.rssi: int | None = None
        self._replies: asyncio.Queue[p.ParamReply] = asyncio.Queue()
        self._cleanup: list = []

    async def __aenter__(self) -> Session:
        from aioesphomeapi import APIClient
        from bleak_esphome import connect_scanner
        from bleak_esphome.backend.client import ESPHomeClient
        from habluetooth import BluetoothManager, set_manager

        mgr = BluetoothManager()
        set_manager(mgr)
        r = mgr.async_setup()
        if r is not None and hasattr(r, "__await__"):
            await r
        api = APIClient(address=self.proxy_host, port=6053, password="", noise_psk=None,
                        client_info="moko")
        await api.connect(login=True)
        self._cleanup.append(api.disconnect)
        cd = connect_scanner(api, await api.device_info(), available=True)
        unsetup = cd.scanner.async_setup()
        unreg = mgr.async_register_scanner(cd.scanner)
        self._cleanup += [_sync(unsetup), _sync(unreg)]

        dev = None
        for _ in range(int(self.scan_seconds / 0.25)):
            for d, adv in cd.scanner.discovered_devices_and_advertisement_data.values():
                if d.address.upper() == self.mac:
                    dev, self.rssi = d, adv.rssi
                    break
            if dev:
                break
            await asyncio.sleep(0.25)
        if dev is None:
            await self._close()
            raise DeviceNotFound(f"{self.mac} is not advertising (out of range, or powered off?)")

        try:
            self._ble = ESPHomeClient(dev, client_data=cd, timeout=30)
            await self._ble.connect(pair=False)
            self._cleanup.insert(0, self._disconnect_ble)
            await self._ble.start_notify(self._char(p.CHAR_PARAMS_NOTIFY), self._on_notify)
            await self._ble.start_notify(self._char(p.CHAR_DISCONNECT_NOTIFY), lambda _d: None)
            await self._unlock()
        except BaseException:
            await self._close()
            raise
        return self

    def _char(self, uuid: str):
        c = self._ble.services.get_characteristic(uuid)
        if c is None:
            raise p.ProtocolError(f"{self.mac} has no characteristic {uuid} -- not a BeaconX Pro tag?")
        return c

    async def _unlock(self) -> None:
        if (await self.read(p.CHAR_LOCK_STATE))[:1] in (b"\x01", b"\x02"):
            return
        challenge = await self.read(p.CHAR_UNLOCK)
        await self._ble.write_gatt_char(self._char(p.CHAR_UNLOCK),
                                        p.unlock_response(self._password, challenge), response=True)
        state = await self.read(p.CHAR_LOCK_STATE)
        if state[:1] not in (b"\x01", b"\x02"):
            raise AuthFailed(f"{self.mac} stayed locked after unlock (lock state {state.hex()}): "
                             "wrong password for this tag?")

    # The backend client (not BleakClient) calls back with the data alone.
    def _on_notify(self, data: bytearray) -> None:
        try:
            self._replies.put_nowait(p.ParamReply.parse(bytes(data)))
        except p.ProtocolError:
            pass

    async def read(self, uuid: str) -> bytes:
        return bytes(await self._ble.read_gatt_char(self._char(uuid)))

    async def write(self, uuid: str, data: bytes) -> None:
        if uuid not in p.WRITABLE or uuid == p.CHAR_PARAMS:
            raise p.Refused(f"write to {uuid} is not allowed")
        await self._ble.write_gatt_char(self._char(uuid), data, response=True)

    async def param(self, frame: bytes, wait: float = 5.0) -> p.ParamReply:
        """Send one EA frame on the command channel; return the EB reply for its key."""
        if frame[:1] != b"\xea" or len(frame) < 4:
            raise p.Refused(f"not a command-channel frame: {frame.hex()}")
        while not self._replies.empty():
            self._replies.get_nowait()
        await self._ble.write_gatt_char(self._char(p.CHAR_PARAMS), frame, response=False)
        deadline = asyncio.get_running_loop().time() + wait
        while True:
            left = deadline - asyncio.get_running_loop().time()
            if left <= 0:
                raise TimeoutError(f"no reply to {frame.hex()}")
            r = await asyncio.wait_for(self._replies.get(), left)
            if r.key in (frame[1], p.KEY_SET_ERROR):
                return r

    async def _disconnect_ble(self) -> None:
        await asyncio.wait_for(self._ble.disconnect(), 15)

    async def _close(self) -> None:
        for fn in self._cleanup:
            try:
                await fn()
            except Exception:  # noqa: BLE001 -- best-effort teardown; keep going
                pass
        self._cleanup = []

    async def __aexit__(self, et: type[BaseException] | None, e: BaseException | None,
                        tb: TracebackType | None) -> None:
        await self._close()


def _sync(fn):
    async def run():
        fn()
    return run
