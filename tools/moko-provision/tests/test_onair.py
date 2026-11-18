import json
from pathlib import Path

from moko import onair
from moko import profile as pf

WANT = pf.render(pf.load(Path(__file__).parent.parent / "profiles" / "fleet.yaml"), minor=1002)
MAC = "F5DD8790E84F"
UUID = "019E42D9FE0870B4BBF26A6FE2470FDA"


def ibeacon_ad(uuid=UUID, major=2000, minor=1002):
    body = "4C000215" + uuid + f"{major:04X}{minor:04X}" + "C5"
    return "020106" + f"{len(body) // 2 + 1:02X}" + "FF" + body


def info_ad(mv=3141):
    # 16 AB FE | 40 00 0A | battery | 00 01 | MAC | 11 00   (layout from the TRA-1009 bench notes)
    body = "ABFE40000A" + f"{mv:04X}" + "0001" + MAC + "1100"
    return f"{len(body) // 2 + 1:02X}" + "16" + body


def tlm_ad(mv=3060):
    body = "AAFE2000" + f"{mv:04X}" + "1940" + "01570D1B" + "0086A6F2"
    return f"{len(body) // 2 + 1:02X}" + "16" + body


def test_classify_each_frame():
    f = onair.classify(ibeacon_ad(), "gw1", 0)
    assert f.kind == "ibeacon"
    assert f.ibeacon == ("019E42D9-FE08-70B4-BBF2-6A6FE2470FDA", 2000, 1002)
    assert onair.classify(info_ad(3141), "gw1", 0) == onair.Frame("info", "gw1", 0, battery_mv=3141)
    assert onair.classify(tlm_ad(3060), "gw1", 0).battery_mv == 3060
    assert onair.classify("09FF7CE913296A3100000505", "gw1", 0).kind == "other"
    assert onair.classify("zz", "gw1", 0).kind == "other"
    assert onair.classify("0516", "gw1", 0).kind == "other"  # truncated


def test_frames_from_message_filters_the_tag():
    msg = {"dev_list": [
        {"mac": MAC, "ts": 1000, "ad": ibeacon_ad(), "rssi": -60},
        {"mac": "CFFBF5816BC9", "ts": 1001, "ad": ibeacon_ad(), "rssi": -60},
        {"mac": MAC.lower(), "ts": 1002, "ad": info_ad(), "rssi": -61},
    ]}
    fs = onair.frames_from_message("trakrf.id/94C960A4E0F0/reads", json.dumps(msg).encode(), MAC)
    assert [(f.kind, f.gateway) for f in fs] == [("ibeacon", "94C960A4E0F0"), ("info", "94C960A4E0F0")]
    assert onair.frames_from_message("t/g/reads", b"not json", MAC) == []


def frames(kind_every: dict[str, int], seconds=60, gateways=("gwA", "gwB"), **ad):
    out = []
    for gw in gateways:
        for kind, every in kind_every.items():
            for t in range(0, seconds * 1000, every):
                a = {"ibeacon": ibeacon_ad, "info": info_ad, "tlm": tlm_ad}[kind]
                out.append(onair.classify(a(**ad.get(kind, {})), gw, t + (7 if gw == "gwB" else 0)))
    return out


def test_profile_on_air_passes():
    rep = onair.judge(frames({"ibeacon": 1000, "info": 10000}), WANT, 60)
    assert rep.passed, rep.problems
    assert rep.intervals == {"info": 10000, "ibeacon": 1000}
    assert rep.battery_mv == 3141


def test_old_two_second_telemetry_fails():
    rep = onair.judge(frames({"ibeacon": 1000, "info": 2000}), WANT, 60)
    assert rep.problems == ["info every ~2000 ms, profile says 10000 ms"]


def test_gateways_are_not_mixed_when_measuring():
    # Two gateways 7 ms apart would look like a 7 ms interval if pooled.
    assert onair.observed_interval_ms(frames({"info": 10000})) == 10000


def bursty(gaps, gw="gw1", kind="info"):
    ts, out = 0, []
    for g in [0] + gaps:
        ts += g
        out.append(onair.classify(info_ad() if kind == "info" else ibeacon_ad(minor=1002), gw, ts))
    return out


# Live, gateway C8F09ED12E1E, Bob at a 10 s device-info interval: each advertising
# event is reported as a burst of sightings within a few hundred ms.
LIVE_10S_BURSTS = [50, 151, 47, 47, 47, 56, 48, 43, 9509, 53, 55, 25, 26, 40, 43, 9514, 52, 301, 9628]


def test_bursts_count_as_one_event():
    assert onair.observed_interval_ms(bursty(LIVE_10S_BURSTS), cluster_ms=600) > 9000
    fs = bursty(LIVE_10S_BURSTS) + bursty([1000] * 60, kind="ibeacon")
    rep = onair.judge(fs, WANT, 60)
    assert rep.passed, rep.problems


def test_old_two_second_telemetry_still_fails_with_clustering():
    rep = onair.judge(bursty([2000] * 30) + bursty([1000] * 60, kind="ibeacon"), WANT, 60)
    assert rep.problems == ["info every ~2000 ms, profile says 10000 ms"]


def test_one_second_ibeacon_seen_half_a_second_apart_is_not_merged():
    assert onair.observed_interval_ms(bursty([494, 506, 1000, 1000], kind="ibeacon"),
                                      cluster_ms=300) == 753  # median of 494, 506, 1000, 1000


def test_wrong_minor_and_leftover_tlm_and_missing_battery():
    rep = onair.judge(frames({"ibeacon": 1000, "tlm": 10000}, ibeacon={"minor": 1000}), WANT, 60)
    assert "no info frames in 60s" in rep.problems
    assert any("iBeacon advertises" in p for p in rep.problems)
    assert "frames the profile turned off are still on air: ['tlm']" in rep.problems


def test_no_battery_at_all():
    rep = onair.judge(frames({"ibeacon": 1000}), WANT, 60)
    assert "no battery reading decoded" in rep.problems
