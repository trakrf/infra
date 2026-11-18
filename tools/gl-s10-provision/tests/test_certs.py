import datetime as dt
import urllib.request

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from gls10 import certs, certserver


def _name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def _cert(subject, issuer, key, signer, ca):
    now = dt.datetime.now(dt.UTC)
    return (
        x509.CertificateBuilder()
        .subject_name(_name(subject))
        .issuer_name(_name(issuer))
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
        .sign(signer, hashes.SHA256())
    )


@pytest.fixture(scope="module")
def chain():
    root_k, int_k, leaf_k = (ec.generate_private_key(ec.SECP256R1()) for _ in range(3))
    root = _cert("Root YE", "Root YE", root_k, root_k, True)
    inter = _cert("YE2", "Root YE", int_k, root_k, True)
    leaf = _cert("mqtt.preview.gke.trakrf.id", "YE2", leaf_k, int_k, False)
    return leaf, inter, root


def test_picks_the_cert_that_signed_the_leaf(chain):
    leaf, inter, root = chain
    assert certs.issuing_intermediate([leaf, root, inter]) == inter


def test_rejects_a_chain_without_the_leaf_issuer(chain):
    leaf, _, root = chain
    with pytest.raises(certs.CertError):
        certs.issuing_intermediate([leaf, root])


def test_rejects_a_same_named_impostor(chain):
    leaf, _, _ = chain
    k = ec.generate_private_key(ec.SECP256R1())
    impostor = _cert("YE2", "YE2", k, k, True)
    with pytest.raises(certs.CertError):
        certs.issuing_intermediate([leaf, impostor])


def test_dummy_client_pair_is_a_matching_self_signed_pair():
    crt_pem, key_pem = certs.dummy_client_pair()
    crt = x509.load_pem_x509_certificate(crt_pem)
    key = serialization.load_pem_private_key(key_pem, password=None)
    assert crt.subject == crt.issuer
    assert crt.public_key().public_numbers() == key.public_key().public_numbers()
    assert key_pem.startswith(b"-----BEGIN PRIVATE KEY-----")


def test_describe_names_subject_and_fingerprint(chain):
    _, inter, _ = chain
    d = certs.describe(inter)
    assert "CN=YE2" in d
    assert inter.fingerprint(hashes.SHA256()).hex(":").upper() in d


def test_server_serves_the_bundle_and_records_each_get():
    bundle = {"ca.crt": b"CA", "client.crt": b"CRT", "client.key": b"KEY"}
    with certserver.CertServer(bundle, host="127.0.0.1") as srv:
        assert srv.base_url.startswith("http://127.0.0.1:") and srv.base_url.endswith("/")
        assert not srv.wait_all(timeout=0.1)
        for name, body in bundle.items():
            with urllib.request.urlopen(srv.base_url + name, timeout=5) as r:
                assert r.read() == body
        assert srv.wait_all(timeout=1)
        assert srv.fetched == set(bundle)


def test_server_404s_anything_outside_its_token_path():
    bundle = {"ca.crt": b"CA", "client.crt": b"CRT", "client.key": b"KEY"}
    with certserver.CertServer(bundle, host="127.0.0.1") as srv:
        root = srv.base_url.rsplit("/", 2)[0] + "/"
        with pytest.raises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(root + "ca.crt", timeout=5)
        assert e.value.code == 404
        assert srv.fetched == set()


def test_lan_ip_for_is_the_local_address_routing_to_the_peer():
    assert certserver.lan_ip_for("127.0.0.1") == "127.0.0.1"
