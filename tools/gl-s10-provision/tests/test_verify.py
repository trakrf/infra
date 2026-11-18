from gls10 import verify

LOG = """\
1795014474: Client 0CB8151E683A already connected, closing old connection.
1795014474: New client connected from 203.0.113.7:60544 as 0CB8151E683A (p2, c1, k120, u'trakrf-mqtt').
1795014500: New client connected from 10.0.0.9:1 as gls10-verify-ab12 (p2, c1, k60, u'trakrf-mqtt').
1795014593: New client connected from 203.0.113.7:52804 as 0CB8151E683A (p2, c1, k120, u'trakrf-mqtt').
not a log line
"""


def test_finds_the_first_connect_at_or_after_t0():
    c = verify.find_connect(LOG, "0CB8151E683A", since=1795014475)
    assert c == verify.Connect(at=1795014593, peer="203.0.113.7:52804")


def test_connect_before_t0_does_not_count():
    assert verify.find_connect(LOG, "0CB8151E683A", since=1795014600) is None


def test_other_client_ids_do_not_count():
    assert verify.find_connect(LOG, "C4DEE229A176", since=0) is None


class FakeWatcher:
    error = None

    def __init__(self, arrivals):
        self.arrivals = arrivals

    def reads_since(self, t):
        return sum(1 for a in self.arrivals if a >= t)


def test_wait_passes_on_connect_then_reads(monkeypatch):
    monkeypatch.setattr(verify, "broker_log", lambda env, since: LOG)
    r = verify.wait_for_unit("preview", "0CB8151E683A", 1795014475,
                             FakeWatcher([1795014600.0]), timeout=0, say=lambda s: None, poll=0)
    assert r.passed and r.connect.at == 1795014593


def test_reads_before_the_connect_do_not_count(monkeypatch):
    monkeypatch.setattr(verify, "broker_log", lambda env, since: LOG)
    r = verify.wait_for_unit("preview", "0CB8151E683A", 1795014475,
                             FakeWatcher([1795014480.0]), timeout=0, say=lambda s: None, poll=0)
    assert not r.passed and r.reads == 0


def test_result_requires_both_connect_and_reads():
    c = verify.Connect(at=1, peer="x")
    assert verify.Result(connect=c, reads=1).passed
    assert not verify.Result(connect=None, reads=3).passed
    assert not verify.Result(connect=c, reads=0).passed
