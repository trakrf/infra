"""gls10 -- provision GL-S10 BLE gateways without the GL.iNet app.

  gls10 ca        --env preview               show the intermediate units must pin
  gls10 info      --mac <BLE MAC>              read-only: device info + MQTT config
  gls10 provision --mac <BLE MAC> --env preview [--ssid <ssid>]   (WIFI_PASS from env)
  gls10 recert    --mac <BLE MAC> --env preview

Secrets never come from argv and are never printed: broker credentials are read
from the cluster, the Wi-Fi password from WIFI_PASS. Requires ESPHOME_PROXY_HOST.
Exit: 0 PASS, 1 FAIL, 2 usage, 75 radio busy.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time
from collections.abc import Callable

from gls10 import certs, creds, plan, verify
from gls10.ble import DeviceNotFound
from gls10 import protocol as p
from gls10.certserver import CertServer, lan_ip_for
from gls10.lock import RadioBusy, radio_lock

EXIT_PASS, EXIT_FAIL, EXIT_USAGE, EXIT_BUSY = 0, 1, 2, 75
READBACK_LABELS = {p.GET_BROKER: "broker", p.GET_CLIENT_ID: "client id", p.GET_TOPICS: "topics"}


class Fail(Exception):
    pass


async def read_config(sess, say: Callable[[str], None]) -> dict[int, list[str]]:
    info = await sess.cmd(p.DEVICE_INFO)
    if info is None or not info.ok:
        raise Fail("no device-info reply")
    d = p.DeviceInfo.parse(info)
    say(f"  device: BLE {d.ble_mac}  base {d.base_mac}  firmware {d.firmware}")
    if p.client_id(d.ble_mac) != p.client_id(sess.mac):
        raise Fail(f"unit reports BLE MAC {d.ble_mac}, expected {sess.mac}")
    got: dict[int, list[str]] = {}
    for c, label in READBACK_LABELS.items():
        r = await sess.cmd(c)
        got[c] = r.fields if r is not None and r.ok else []
        say(f"  {label}: {got[c]}")
    return got


async def write_steps(sess, steps: list[plan.Step], say: Callable[[str], None]) -> None:
    for st in steps:
        r = await sess.cmd(st.cmd, st.data, wait=st.wait)
        shown = "<secret>" if st.secret else repr(st.data.decode("utf-8", "replace"))
        if r is None or not r.ok:
            why = "no reply" if r is None else f"status {r.body[:1].hex() or '-'} crc_ok={r.crc_ok}"
            raise Fail(f"0x{st.cmd:02x} {st.label} {shown}: {why}")
        say(f"  0x{st.cmd:02x} {st.label} {shown}: OK")


async def configure(sess, steps: list[plan.Step], expected: dict[int, list[str]],
                    server, fetch_timeout: float, say: Callable[[str], None]) -> float:
    """Write `steps`, check read-back, wait for the cert fetch, reboot.

    Returns the epoch time the reboot was sent. Raises Fail before the reboot on
    any refused write or read-back mismatch, leaving the unit in config mode.
    """
    say("== before ==")
    await read_config(sess, say)
    say("== write ==")
    await write_steps(sess, steps, say)
    if expected:
        say("== read back ==")
        got = await read_config(sess, say)
        bad = [READBACK_LABELS[c] for c, want in expected.items() if got.get(c) != want]
        if bad:
            raise Fail(f"read-back mismatch: {', '.join(bad)}")
    say(f"== cert fetch (up to {fetch_timeout:.0f}s) ==")
    if await asyncio.to_thread(server.wait_all, fetch_timeout):
        say("  unit fetched ca.crt, client.crt, client.key")
    else:
        say(f"  not yet fetched (got {sorted(server.fetched)}); rebooting and still waiting")
    t0 = time.time()
    await sess.cmd(p.REBOOT, wait=3)  # the unit drops BLE; a missing reply is expected
    say("  0x22 reboot sent")
    return t0


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="gls10", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="action", required=True)
    ca = sub.add_parser("ca", help="show the broker's issuing intermediate")
    ca.add_argument("--env", choices=creds.ENVS, required=True)
    for name in ("info", "provision", "recert"):
        sp = sub.add_parser(name)
        sp.add_argument("--mac", required=True, help="BLE MAC (base MAC + 2)")
        sp.add_argument("--scan-seconds", type=float, default=20)
        if name == "info":
            continue
        sp.add_argument("--env", choices=creds.ENVS, required=True)
        sp.add_argument("--serve-ip", help="LAN IP to serve certs on (default: route to proxy)")
        sp.add_argument("--serve-port", type=int, default=0)
        sp.add_argument("--fetch-timeout", type=float, default=60)
        sp.add_argument("--verify-timeout", type=float, default=180)
        sp.add_argument("--topic-base", default="trakrf.id")
        if name == "provision":
            sp.add_argument("--ssid", help="also join this Wi-Fi; password from env WIFI_PASS")
    return ap


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    mask = creds.Masker()

    def say(s: str) -> None:
        print(mask(s), flush=True)

    try:
        if args.action == "ca":
            _, inter = certs.bundle_for(creds.broker_host(args.env))
            say(f"{creds.broker_host(args.env)} is signed by {certs.describe(inter)}")
            return EXIT_PASS
        proxy = os.environ.get("ESPHOME_PROXY_HOST")
        if not proxy:
            say("ESPHOME_PROXY_HOST is not set")
            return EXIT_USAGE
        if args.action == "info":
            return asyncio.run(_info(args, proxy, say))
        return _write(args, proxy, mask, say)
    except RadioBusy as e:
        say(str(e))
        return EXIT_BUSY
    except (Fail, DeviceNotFound) as e:
        say(f"FAIL: {e}")
        return EXIT_FAIL


async def _info(args, proxy: str, say) -> int:
    from gls10.ble import Session

    with radio_lock("gls10-info"):
        async with Session(proxy, args.mac, args.scan_seconds) as sess:
            say(f"found {sess.mac} rssi={sess.rssi}")
            await read_config(sess, say)
    return EXIT_PASS


def _write(args, proxy: str, mask: creds.Masker, say) -> int:
    from gls10.ble import Session

    cid = p.client_id(args.mac)
    bc = creds.broker_creds(args.env)
    mask.add(bc.password)
    wifi = None
    if getattr(args, "ssid", None):
        pw = os.environ.get("WIFI_PASS")
        if not pw:
            say("--ssid needs the Wi-Fi password in env WIFI_PASS")
            return EXIT_USAGE
        mask.add(pw)
        wifi = (args.ssid, pw)

    bundle, inter = certs.bundle_for(bc.host)
    say(f"ca.crt: {certs.describe(inter)}")
    serve_ip = args.serve_ip or lan_ip_for(proxy)

    with CertServer(bundle, host=serve_ip, port=args.serve_port) as server:
        say(f"serving certs at {server.base_url}")
        if args.action == "provision":
            steps = plan.provision(bc.uri, cid, args.topic_base, server.base_url, wifi)
            expected = plan.expected_config(bc.uri, cid, args.topic_base)
            reads_topic = p.topics(args.topic_base, cid)[1]
        else:
            steps, expected = plan.recert(server.base_url), {}
            reads_topic = p.topics(args.topic_base, cid)[1]

        with verify.ReadsWatcher(bc, reads_topic) as watcher:
            with radio_lock(f"gls10-{args.action}"):
                t0 = asyncio.run(_ble(Session(proxy, args.mac, args.scan_seconds), steps,
                                      expected, server, args.fetch_timeout, say))
            say(f"== verify on {bc.host} (up to {args.verify_timeout:.0f}s) ==")
            result = verify.wait_for_unit(args.env, cid, int(t0), watcher,
                                          args.verify_timeout, say)
        fetched = server.fetched >= set(bundle)
        for line in server.log:
            say(f"  http: {line}")

    say("== result ==")
    say(f"  certs fetched:     {'yes' if fetched else 'NO'}")
    say(f"  broker connect:    {'yes' if result.connect else 'NO'}")
    say(f"  reads after it:    {result.reads}")
    if watcher.error:
        say(f"  {watcher.error}")
    ok = fetched and result.passed
    say(f"{'PASS' if ok else 'FAIL'} {cid}")
    return EXIT_PASS if ok else EXIT_FAIL


async def _ble(sess, steps, expected, server, fetch_timeout, say) -> float:
    async with sess:
        say(f"found {sess.mac} rssi={sess.rssi}")
        return await configure(sess, steps, expected, server, fetch_timeout, say)


if __name__ == "__main__":
    sys.exit(main())
