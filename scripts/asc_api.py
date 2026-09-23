"""Minimal App Store Connect API client: an ES256 token and one request helper.

Standard library plus `cryptography`, nothing else. Reads the same environment
as `archive.sh --upload`:

    ASC_KEY_ID, ASC_ISSUER_ID   (key at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8)
"""
import base64, json, os, sys, time, urllib.error, urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

API = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6815015600"  # hubHub — Repo Stats, com.giovannicoppola.hubhub


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token():
    key_id, issuer = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        sys.exit("set ASC_KEY_ID and ASC_ISSUER_ID")
    path = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    key = serialization.load_pem_private_key(open(path, "rb").read(), None)
    header = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    # Apple caps a token at 20 minutes.
    claims = _b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"}).encode())
    r, s = decode_dss_signature(key.sign(f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256())))
    return f"{header}.{claims}.{_b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


_token = None


def call(method, url, body=None, headers=None, raw=None):
    """One request. Exits with Apple's error body on failure — it names the bad field."""
    global _token
    if not url.startswith("http"):
        url = API + url
    if headers is None:
        _token = _token or token()
        headers = {"Authorization": f"Bearer {_token}", "Content-Type": "application/json"}
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=headers)) as resp:
            text = resp.read()
            return json.loads(text) if text and resp.headers.get_content_type() == "application/json" else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} -> {e.code}\n{e.read().decode()}")


def editable_version():
    """The iOS version still open for edits (not yet submitted or released)."""
    versions = call("GET", f"/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS")["data"]
    for v in versions:
        if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED",
                                                "REJECTED", "METADATA_REJECTED"):
            return v
    sys.exit("No editable version: " + ", ".join(
        f"{v['attributes']['versionString']} {v['attributes']['appStoreState']}" for v in versions))
