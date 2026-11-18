import pytest

from moko import profile as pf
from moko import protocol as p

PROFILE = {
    "button_power_off": True,
    "name": "TrakRF",
    "slots": [
        {"frame": "info", "interval_ms": 10000, "radio_tx_dbm": 0, "ranging_dbm": 0},
        {"frame": "ibeacon", "uuid": "019e42d9-fe08-70b4-bbf2-6a6fe2470fda", "major": 2000,
         "minor": "per-tag", "interval_ms": 1000, "radio_tx_dbm": 0, "ranging_dbm": -59},
    ],
}


def alice_now() -> dict:
    """Alice's state as the capture read it."""
    return {
        "button_power_off": False,
        "slots": [
            {"frame": "info", "name": "Notify", "interval_ms": 1000, "radio_tx_dbm": 0,
             "ranging_dbm": 0, "trigger": {"type": "none"}},
            {"frame": "ibeacon", "uuid": "EB165B98-0621-10AB-0250-37C882308E5F", "major": 2000,
             "minor": 1000, "interval_ms": 1000, "radio_tx_dbm": 0, "ranging_dbm": 0,
             "trigger": {"type": "none"}},
        ] + [{"frame": "off"}] * 4,
    }


def test_render_fills_per_tag_values_and_pads_off_slots():
    want = pf.render(PROFILE, minor=1001)
    assert len(want["slots"]) == p.SLOTS
    assert want["slots"][0]["name"] == "TrakRF"
    assert want["slots"][0]["trigger"] == {"type": "none"}
    assert want["slots"][1]["minor"] == 1001
    assert want["slots"][1]["uuid"] == "019E42D9-FE08-70B4-BBF2-6A6FE2470FDA"
    assert want["slots"][2:] == [{"frame": "off"}] * 4
    assert pf.render(PROFILE, minor=7, name="Bob")["slots"][0]["name"] == "Bob"


def test_render_requires_minor_when_profile_asks_for_one():
    with pytest.raises(pf.ProfileError, match="minor"):
        pf.render(PROFILE)


@pytest.mark.parametrize("mutate, match", [
    (lambda d: d["slots"].append({"frame": "off"}) or d["slots"].extend([{"frame": "off"}] * 4), "slots"),
    (lambda d: d["slots"][0].update(interval_ms=60000), "interval"),
    (lambda d: d["slots"][0].update(radio_tx_dbm=5), "radio tx"),
    (lambda d: d["slots"][1].pop("uuid"), "uuid"),
    (lambda d: d["slots"][0].update(frame="url"), "frame"),
    (lambda d: d["slots"][0].update(colour="blue"), "colour"),
    (lambda d: d.update(name="x" * 21), "name"),
])
def test_render_rejects_bad_profiles(mutate, match):
    import copy

    bad = copy.deepcopy(PROFILE)
    mutate(bad)
    with pytest.raises(pf.ProfileError, match=match):
        pf.render(bad, minor=1)


def test_plan_against_alice_writes_only_what_differs():
    want = pf.render(PROFILE, minor=1001)
    steps = pf.plan(alice_now(), want)
    labels = [s.label for s in steps]
    # slot 0: name + interval change -> whole slot rewritten in the app's order
    # slot 1: uuid/minor/ranging change -> whole slot rewritten
    # slots 2-5 already off -> nothing; button power differs -> one param write
    assert labels == [
        "slot 0 select", "slot 0 data", "slot 0 radio tx", "slot 0 ranging", "slot 0 interval", "slot 0 trigger",
        "slot 1 select", "slot 1 data", "slot 1 radio tx", "slot 1 ranging", "slot 1 interval", "slot 1 trigger",
        "button power-off",
    ]
    by = {s.label: s for s in steps}
    assert by["slot 0 data"].char == p.CHAR_SLOT_DATA
    assert by["slot 0 data"].data == b"\x40TrakRF"
    assert by["slot 1 select"].data == b"\x01"
    assert by["slot 1 interval"].data == bytes.fromhex("03e8")
    assert by["slot 1 ranging"].data == b"\xc5"
    assert by["slot 0 trigger"].char == p.CHAR_PARAMS
    assert by["slot 0 trigger"].data == bytes.fromhex("ea39000100")
    assert by["button power-off"].data == bytes.fromhex("ea38000101")


def test_plan_turns_off_an_extra_slot_with_one_write():
    now = alice_now()
    now["slots"][2] = {"frame": "tlm", "interval_ms": 2000, "radio_tx_dbm": 0, "ranging_dbm": 0,
                       "trigger": {"type": "none"}}
    steps = [s for s in pf.plan(now, pf.render(PROFILE, minor=1001)) if s.label.startswith("slot 2")]
    assert [(s.label, s.data) for s in steps] == [("slot 2 select", b"\x02"), ("slot 2 data", b"\xff")]


def test_plan_is_empty_when_tag_already_matches():
    want = pf.render(PROFILE, minor=1001)
    assert pf.plan(want, want) == []
    assert pf.mismatches(want, want) == []


def test_mismatches_name_the_fields():
    want = pf.render(PROFILE, minor=1001)
    got = pf.render(PROFILE, minor=1002)
    got["button_power_off"] = False
    assert pf.mismatches(got, want) == ["slot 1 minor: have 1002, want 1001",
                                        "button_power_off: have False, want True"]


def test_mismatches_ignore_settings_of_off_slots():
    want = pf.render(PROFILE, minor=1)
    got = pf.render(PROFILE, minor=1)
    got["slots"][3] = {"frame": "off", "interval_ms": 1000, "radio_tx_dbm": 0}
    assert pf.mismatches(got, want) == []


def test_unknown_trigger_on_a_live_slot_is_rewritten():
    now = pf.render(PROFILE, minor=1)
    now["slots"][1]["trigger"] = {"type": "move", "raw": "003c02"}
    steps = pf.plan(now, pf.render(PROFILE, minor=1))
    assert [s.label for s in steps][-1] == "slot 1 trigger"


def test_load_shipped_profile():
    from pathlib import Path

    prof = pf.load(Path(__file__).parent.parent / "profiles" / "fleet.yaml")
    want = pf.render(prof, minor=1001)
    assert want["button_power_off"] is True
    frames = [s["frame"] for s in want["slots"]]
    assert frames.count("ibeacon") == 1 and frames.count("off") == 4


def test_batch_file(tmp_path):
    f = tmp_path / "tags.csv"
    f.write_text("# mac, minor, name\nF5DD8790E84F,1002,Bob\ncf:fb:f5:81:6b:c9, 1001\n\n")
    assert pf.load_batch(f) == [
        pf.Tag("F5:DD:87:90:E8:4F", 1002, "Bob"),
        pf.Tag("CF:FB:F5:81:6B:C9", 1001, None),
    ]
    f.write_text("F5DD8790E84F,1002\nF5DD8790E84F,1003\n")
    with pytest.raises(pf.ProfileError, match="twice"):
        pf.load_batch(f)
    f.write_text("F5DD8790E84F,1002\nCFFBF5816BC9,1002\n")
    with pytest.raises(pf.ProfileError, match="minor 1002"):
        pf.load_batch(f)
