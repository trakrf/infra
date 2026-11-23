"""moko -- provision MokoSmart BeaconX Pro tags without the BeaconX Pro app.

  moko read   --mac <MAC>                               every slot, triggers, battery -> JSON
  moko apply  --mac <MAC> [--name <name>]              apply the profile; read back; PASS/FAIL
  moko batch  --file tags.csv                           apply to every tag in the file
  moko verify --mac <MAC> --env preview                 check the gateways see the profile on air

`apply` and `batch` take --profile (default profiles/fleet.yaml), --dry-run, and
--verify-env to run `verify` after writing. The tag password comes from the env
var named by --password-env (default NOTIFY_BLE_PASSWORD) or from --password-file;
never from argv, and it is never printed. Requires ESPHOME_PROXY_HOST.
Exit: 0 PASS, 1 FAIL, 2 usage, 75 radio busy.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from gls10.creds import ENVS, Masker
from gls10.lock import RadioBusy, radio_lock

from moko import device, onair, profile as pf, protocol as p
from moko.ble import AuthFailed, DeviceNotFound

# A per-tag failure: reported as FAIL, and a batch moves on to the next tag.
# BleakError covers the proxy refusing or dropping the GATT connection.
from bleak.exc import BleakError

TAG_ERRORS = (device.ApplyError, DeviceNotFound, AuthFailed, p.ProtocolError, TimeoutError,
              BleakError)

EXIT_PASS, EXIT_FAIL, EXIT_USAGE, EXIT_BUSY = 0, 1, 2, 75
DEFAULT_PROFILE = Path(__file__).resolve().parents[2] / "profiles" / "fleet.yaml"
DEFAULT_PASSWORD_ENV = "NOTIFY_BLE_PASSWORD"


class Usage(Exception):
    pass


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="moko", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="action", required=True)
    for name in ("read", "apply", "batch", "verify"):
        sp = sub.add_parser(name)
        if name == "batch":
            sp.add_argument("--file", type=Path, required=True, help="CSV: mac[, name]")
        else:
            sp.add_argument("--mac", required=True)
        if name in ("apply", "verify"):
            sp.add_argument("--name", help="device name (default: the profile's)")
        if name != "read":
            sp.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
        if name in ("apply", "batch"):
            sp.add_argument("--dry-run", action="store_true", help="read and diff; write nothing")
            sp.add_argument("--verify-env", choices=ENVS, help="then watch the gateways on this env")
        if name == "verify":
            sp.add_argument("--env", choices=ENVS, required=True)
        if name in ("apply", "batch", "verify"):
            sp.add_argument("--verify-seconds", type=float, default=60)
            sp.add_argument("--topic-base", default="trakrf.id")
        if name != "verify":
            sp.add_argument("--password-env", default=DEFAULT_PASSWORD_ENV)
            sp.add_argument("--password-file", type=Path)
            sp.add_argument("--scan-seconds", type=float, default=20)
    return ap


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    mask = Masker()

    def say(s: str) -> None:  # progress goes to stderr; stdout is JSON for `read`
        print(mask(s), file=sys.stderr, flush=True)

    try:
        if args.action == "verify":
            tag = pf.Tag(p.colon_mac(args.mac), args.name)
            want = pf.render(pf.load(args.profile), name=tag.name)
            return EXIT_PASS if verify_many([(tag, want)], args, say) else EXIT_FAIL
        password = _password(args)
        mask.add(password)
        proxy = os.environ.get("ESPHOME_PROXY_HOST")
        if not proxy:
            raise Usage("ESPHOME_PROXY_HOST is not set")
        if args.action == "read":
            with radio_lock("moko-read"):
                state = asyncio.run(_read(proxy, args.mac, password, args.scan_seconds, say))
            print(json.dumps(state, indent=2))
            return EXIT_PASS
        prof = pf.load(args.profile)
        if args.action == "apply":
            tags = [pf.Tag(p.colon_mac(args.mac), args.name)]
        else:
            tags = pf.load_batch(args.file)
        wants = [(t, pf.render(prof, name=t.name)) for t in tags]  # fail before radio
        return run_apply(wants, proxy, password, args, say)
    except RadioBusy as e:
        say(str(e))
        return EXIT_BUSY
    except (Usage, pf.ProfileError, ValueError) as e:
        say(f"usage: {e}")
        return EXIT_USAGE
    except TAG_ERRORS as e:
        say(f"FAIL: {e}")
        return EXIT_FAIL


def _password(args) -> str:
    if args.password_file:
        pw = args.password_file.read_text().strip()
    else:
        pw = os.environ.get(args.password_env, "")
    if not pw:
        raise Usage(f"no tag password: set {args.password_env} or pass --password-file")
    p.unlock_key(pw)  # validates length/charset without echoing it
    return pw


async def _read(proxy, mac, password, scan_seconds, say) -> dict:
    from moko.ble import Session

    async with Session(proxy, mac, password, scan_seconds) as sess:
        say(f"connected {sess.mac} rssi={sess.rssi}, unlocked")
        return await device.read_state(sess)


@dataclass
class Row:
    tag: pf.Tag
    result: str = "FAIL"
    writes: int = 0
    battery_mv: int | None = None
    note: str = ""


def run_apply(wants, proxy, password, args, say) -> int:
    from moko.ble import Session

    rows: list[Row] = []
    with radio_lock(f"moko-{args.action}"):
        for tag, want in wants:
            row = Row(tag)
            rows.append(row)
            say(f"== {tag.mac} ==")
            try:
                out = asyncio.run(_apply_one(Session(proxy, tag.mac, password, args.scan_seconds),
                                             want, args.dry_run, say))
            except TAG_ERRORS as e:
                row.note = str(e)
                say(f"  FAIL: {e}")
                continue
            row.writes = len(out.steps)
            row.battery_mv = out.before.get("battery_mv")
            if args.dry_run:
                row.result = "DRY-RUN"
                row.note = "; ".join(out.mismatches) or "already matches"
            elif out.passed:
                row.result = "PASS"
                row.note = "no-op" if not out.steps else "written, read back OK"
            else:
                row.note = "read-back: " + "; ".join(out.mismatches)
            say(f"  {row.result}: {row.note}")

    if args.verify_env and not args.dry_run:
        ok = [(r.tag, w) for r, (_, w) in zip(rows, wants) if r.result == "PASS"]
        if ok:
            results = verify_many(ok, args, say, env=args.verify_env)
            for r in rows:
                if r.result == "PASS" and not results.get(r.tag.mac, False):
                    r.result, r.note = "FAIL", r.note + "; not as profiled on air"

    say("")
    say(f"{'MAC':<17}  {'result':<7}  {'writes':>6}  {'batt mV':>7}  note")
    for r in rows:
        say(f"{r.tag.mac:<17}  {r.result:<7}  {r.writes:>6}  "
            f"{r.battery_mv!s:>7}  {r.note}")
    return EXIT_PASS if all(r.result in ("PASS", "DRY-RUN") for r in rows) else EXIT_FAIL


async def _apply_one(session, want, dry_run, say) -> device.Outcome:
    async with session as sess:
        say(f"  connected rssi={sess.rssi}, unlocked")
        return await device.apply(sess, want, say, dry_run=dry_run)


def verify_many(tags_wants, args, say, env: str | None = None) -> dict[str, bool]:
    """Watch every gateway for --verify-seconds; judge each tag. Returns mac -> passed."""
    from contextlib import ExitStack

    from gls10.creds import broker_creds

    env = env or args.env
    creds = broker_creds(env)
    say(f"== on air via {creds.host} for {args.verify_seconds:.0f}s ==")
    results: dict[str, bool] = {}
    with ExitStack() as stack:
        watchers = [(t, w, stack.enter_context(onair.Watcher(creds, args.topic_base, p.bare_mac(t.mac))))
                    for t, w in tags_wants]
        time.sleep(args.verify_seconds)
        for t, w, watcher in watchers:
            if watcher.error:
                say(f"  {t.mac}: {watcher.error}")
                results[t.mac] = False
                continue
            rep = onair.judge(watcher.snapshot(), w, args.verify_seconds)
            ivs = ", ".join(f"{k} ~{v} ms" for k, v in rep.intervals.items())
            say(f"  {t.mac}: seen {rep.seen}; {ivs}; battery {rep.battery_mv} mV")
            for prob in rep.problems:
                say(f"    - {prob}")
            say(f"  {t.mac}: {'PASS' if rep.passed else 'FAIL'} on air")
            results[t.mac] = rep.passed
    return results


if __name__ == "__main__":
    sys.exit(main())
