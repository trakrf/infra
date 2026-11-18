"""The three files a GL-S10 fetches on a cert update.

  ca.crt      the intermediate that directly signs the broker's leaf. The unit
              pins that one cert -- not the root, not a bundle -- so when Let's
              Encrypt renews onto a different intermediate, every unit must be
              re-certed.
  client.crt  a throwaway self-signed cert. The broker does not ask for client
  client.key  certs, but the unit refuses an update without all three files.
"""

from __future__ import annotations

import datetime as dt
import socket
import ssl

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


class CertError(Exception):
    pass


def fetch_chain(host: str, port: int = 8883, timeout: float = 10) -> list[x509.Certificate]:
    """The chain the broker presents, leaf first, after normal verification."""
    ctx = ssl.create_default_context()
    # The units speak TLS 1.2 only; look at the chain they will see.
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    with socket.create_connection((host, port), timeout=timeout) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            ders = tls.get_unverified_chain()
    return [x509.load_der_x509_certificate(d) for d in ders]


def issuing_intermediate(chain: list[x509.Certificate]) -> x509.Certificate:
    """The cert in the presented chain that signed the leaf (chain[0])."""
    leaf = chain[0]
    for cand in chain[1:]:
        if cand.subject != leaf.issuer:
            continue
        try:
            leaf.verify_directly_issued_by(cand)
        except (InvalidSignature, ValueError, TypeError):
            continue
        return cand
    raise CertError(f"broker chain has no verified issuer for leaf {leaf.subject.rfc4514_string()}")


def describe(cert: x509.Certificate) -> str:
    fp = cert.fingerprint(hashes.SHA256()).hex(":").upper()
    return (
        f"{cert.subject.rfc4514_string()}  "
        f"(expires {cert.not_valid_after_utc:%Y-%m-%d})  sha256 {fp}"
    )


def pem(cert: x509.Certificate) -> bytes:
    return cert.public_bytes(serialization.Encoding.PEM)


def dummy_client_pair() -> tuple[bytes, bytes]:
    """A fresh self-signed RSA-2048 cert and its PKCS#8 key, both PEM."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "gls10-dummy")])
    now = dt.datetime.now(dt.UTC)
    crt = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=3650))
        .sign(key, hashes.SHA256())
    )
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return crt.public_bytes(serialization.Encoding.PEM), key_pem


def bundle_for(host: str, port: int = 8883) -> tuple[dict[str, bytes], x509.Certificate]:
    inter = issuing_intermediate(fetch_chain(host, port))
    crt, key = dummy_client_pair()
    return {"ca.crt": pem(inter), "client.crt": crt, "client.key": key}, inter
