"""A BLE session with one GL-S10, through an ESPHome Bluetooth proxy.

Nothing here runs unless the caller holds the radio lock (see lock.py).
"""

from __future__ import annotations

import asyncio
from types import TracebackType

from gls10 import protocol as p


class DeviceNotFound(Exception):
    pass


class Session:
    def __init__(self, proxy_host: str, ble_mac: str, scan_seconds: float = 20.0):
        self.proxy_host = proxy_host
        self.mac = p.colon_mac(ble_mac)
        self.codec = p.Codec(ble_mac)
        self.scan_seconds = scan_seconds
        self.rssi: int | None = None
        self._count = 1
        self._inbox: asyncio.Queue[p.Reply] = asyncio.Queue()
        self._ra = p.Reassembler()
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
                        client_info="gls10")
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
            raise DeviceNotFound(f"{self.mac} is not advertising -- is it in pairing mode?")

        self._ble = ESPHomeClient(dev, client_data=cd, timeout=30)
        await self._ble.connect(pair=False)
        self._cleanup.insert(0, self._disconnect_ble)
        await self._ble.start_notify(self._ble.services.get_characteristic(p.NOTIFY_CHAR),
                                     self._on_notify)
        self._write_char = self._ble.services.get_characteristic(p.WRITE_CHAR)
        return self

    # The backend client (not BleakClient) calls back with the data alone.
    def _on_notify(self, data: bytearray) -> None:
        frame = self._ra.feed(bytes(data))
        if frame is not None:
            try:
                self._inbox.put_nowait(self.codec.decode(frame))
            except p.ProtocolError:
                pass

    async def cmd(self, cmd: int, data: bytes = b"", wait: float = 6.0) -> p.Reply | None:
        """Send one command; return its reply, or None on timeout."""
        frame = self.codec.encode(cmd, data, self._count)  # refuses FORBIDDEN
        while not self._inbox.empty():
            self._inbox.get_nowait()
        await self._ble.write_gatt_char(self._write_char, frame, response=True)
        self._count += 1
        try:
            return await asyncio.wait_for(self._inbox.get(), wait)
        except TimeoutError:
            return None

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
