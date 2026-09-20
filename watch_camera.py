#!/usr/bin/env python
"""See an Ivideon camera on this PC: log in, list cameras, build the signed
live-stream URL, and play it with ffplay.

Everything the protocol needs was reconstructed from the Ivideon Android app
3.7.1 (see INTEGRATION.md). The auth request shape is verified against the live
server; the camera-list shape and the URL signature are NOT yet verified live,
so the first run may need a fix. Use --raw to print the server's answers (secrets
are redacted) and share that if a step fails.

Usage (password is asked locally; it is never printed or sent to anyone but Ivideon):
    python watch_camera.py                 # log in, list cameras
    python watch_camera.py --play          # ... and play the (only/first) camera
    python watch_camera.py --camera <id> --play --q 2
    python watch_camera.py --url           # just print the signed live URL
    python watch_camera.py --raw           # show redacted server responses for debugging
    python watch_camera.py --logout        # forget the saved token

Env vars IVIDEON_EMAIL / IVIDEON_PASSWORD are used if set (handy, avoids the prompt).
"""
import argparse
import getpass
import hashlib
import hmac
import json
import os
import random
import shutil
import string
import subprocess
import sys
import time
import uuid

AUTH_HOST = "https://openapi-alpha-eu01.ivideon.com"   # verified: api.ivideon.com/auth redirects here
DEFAULT_API = "https://api.ivideon.com"
BASIC = "Basic YW5kcm9pZC1jbGllbnQ6"                    # base64("android-client:")
CLIENT_VERSION = "3.7.1"
STATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".ivideon")
TOKEN_FILE = os.path.join(STATE_DIR, "token.json")
DEVICE_FILE = os.path.join(STATE_DIR, "device.json")
CHALLENGE_FILE = os.path.join(STATE_DIR, "challenge.json")
CAMERA_FILE = os.path.join(STATE_DIR, "camera.json")

# Camera projection the app requests (from r23.java) — best guess for the live shape.
CAMERA_PROJECTION = {
    "id": 1, "name": 1, "online": 1, "connected": 1, "permissions": 1,
    "features": 1, "width": 1, "height": 1,
}
SERVER_PROJECTION = {
    "id": 1, "owner": 1, "connected": 1, "online": 1, "name": 1,
    "device_type": 1, "software_version": 1, "device_model": 1, "vendor": 1,
    "cameras": CAMERA_PROJECTION,
}

# ---- OkHttp query-component encoding, matching zig-client/src/sign.zig ----
_SAFE = set(string.ascii_letters + string.digits + "-._*")


def q_enc(s):
    return "".join(c if c in _SAFE else "".join("%%%02X" % b for b in c.encode("utf-8")) for c in s)


def sign_url(base_url, path, params, token, secret, session, counter, method="GET", body=""):
    """Return the fully signed stream URL (see INTEGRATION.md 3.4)."""
    all_params = list(params) + [("access_token", token)]
    signed = bool(secret)
    if signed:
        all_params.append(("cseq", "%s:%d" % (session, counter)))
    query = "&".join("%s=%s" % (q_enc(k), q_enc(v)) for k, v in all_params)
    url = "%s%s?%s" % (base_url, path, query)
    if signed:
        to_sign = ":".join([method, path, query, body])
        digest = hashlib.sha1(to_sign.encode()).hexdigest()
        cs = hmac.new(secret.encode(), digest.encode(), hashlib.sha1).hexdigest()
        url += "&cs=" + cs
    return url


# ---- tiny HTTP via curl (robust TLS + redirect handling) ----
def curl(method, url, headers=None, data=None, form=False):
    cmd = ["curl", "-sS", "-m", "45", "-L", "-X", method, "-w", "\n__HTTP__%{http_code}"]
    for k, v in (headers or {}).items():
        cmd += ["-H", "%s: %s" % (k, v)]
    if form:
        for k, v in data.items():
            cmd += ["--data-urlencode", "%s=%s" % (k, v)]
    elif data is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(data)]
    cmd.append(url)
    out = subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout
    body, _, code = out.rpartition("\n__HTTP__")
    return int(code or 0), body


def redact(obj):
    if isinstance(obj, dict):
        return {k: ("<redacted>" if k in ("access_token", "refresh_token", "hmac_secret", "password") else redact(v))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    return obj


def device_info():
    os.makedirs(STATE_DIR, exist_ok=True)
    try:
        with open(DEVICE_FILE) as f:
            return json.load(f)
    except Exception:
        d = {"instance_id": str(uuid.uuid4()), "name": "ivideon-tools", "type": "reverse client, Windows"}
        with open(DEVICE_FILE, "w") as f:
            json.dump(d, f)
        return d


def login(email, password, raw=False):
    dev = device_info()
    fields = {
        "grant_type": "password", "username": email, "password": password,
        "client_type": "android", "client_version": CLIENT_VERSION,
        "device_instance_id": dev["instance_id"], "device_type": dev["type"], "device_name": dev["name"],
        "trusted_device": "true",
    }
    code, body = curl("POST", AUTH_HOST + "/auth/oauth/token?client_id=android-client",
                      {"Authorization": BASIC}, fields, form=True)
    try:
        tok = json.loads(body)
    except Exception:
        die("Auth host returned non-JSON (HTTP %d):\n%s" % (code, body[:500]))
    if raw:
        print("=== login HTTP %d ===\n%s\n" % (code, json.dumps(redact(tok), indent=2, ensure_ascii=False)))
    if tok.get("proceed_with_2fa"):
        return {"_2fa": tok}
    if code != 200 or "access_token" not in tok:
        reason = tok.get("reason") or tok.get("error_description") or tok.get("error") or body[:300]
        if tok.get("limited_to_2fa"):
            die("Account returned a 2FA-limited token — 2FA must be finished in the official Ivideon app first.")
        die("Login failed (HTTP %d): %s" % (code, reason))
    return save_token(tok)


def save_token(tok):
    tok["_saved_at"] = int(time.time())
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(TOKEN_FILE, "w") as f:
        json.dump(tok, f)
    print("Logged in. Token saved to %s" % TOKEN_FILE)
    return tok


def twofa_begin(chal, raw=False):
    """Ask the server to send the 2FA code, and remember the challenge for --code."""
    methods = chal.get("available_methods") or []
    if not methods:
        die("2FA required but the server offered no methods.")
    m = next((x for x in methods if x.get("type") == "sms"), methods[0])
    api5 = chal["api5_host"]
    if not api5.startswith("http"):
        api5 = "https://" + api5
    ct = chal["challenge_token"]
    code, body = curl("POST", "%s/two_factor_methods/%s?op=SELECT" % (api5, m["id"]),
                      {"Authorization": BASIC}, {"challenge_token": ct})
    if raw:
        print("=== SELECT HTTP %d ===\n%s\n" % (code, body[:600]))
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(CHALLENGE_FILE, "w") as f:
        json.dump({"challenge_token": ct, "api5_host": api5, "method_id": m["id"],
                   "value": m.get("value"), "type": m.get("type"), "saved_at": int(time.time())}, f)
    print("\nA %s code was sent to %s." % ((m.get("type") or "verification").upper(), m.get("value") or "your device"))
    print("Give me the code, then I run:  python watch_camera.py --code <CODE> --play")


def twofa_finish(code_value, raw=False):
    """Submit the 2FA code and, on success, save the real token."""
    try:
        with open(CHALLENGE_FILE) as f:
            chal = json.load(f)
    except Exception:
        die("No pending 2FA challenge — run login first (without --code).")
    url = "%s/two_factor_methods/%s/code?op=SUBMIT" % (chal["api5_host"], chal["method_id"])
    code, body = curl("POST", url, {"Authorization": BASIC},
                      {"challenge_token": chal["challenge_token"], "code": str(code_value).strip()})
    try:
        data = json.loads(body)
    except Exception:
        die("2FA submit returned non-JSON (HTTP %d):\n%s" % (code, body[:500]))
    if isinstance(data, dict) and "result" in data and "access_token" not in data:
        data = data["result"]
    if raw:
        print("=== SUBMIT HTTP %d ===\n%s\n" % (code, json.dumps(redact(data), indent=2, ensure_ascii=False)))
    if not isinstance(data, dict) or "access_token" not in data:
        reason = ((data.get("reason") or data.get("code") or data.get("error_description")
                   or data.get("message") or body[:300]) if isinstance(data, dict) else body[:300])
        die("2FA failed (HTTP %d): %s" % (code, reason))
    try:
        os.remove(CHALLENGE_FILE)
    except OSError:
        pass
    return save_token(data)


def load_token():
    try:
        with open(TOKEN_FILE) as f:
            return json.load(f)
    except Exception:
        return None


def api_base(tok):
    host = tok.get("api_host") or ""
    if host and not host.startswith("http"):
        host = "https://" + host
    return host or DEFAULT_API


def find_cameras(tok, raw=False):
    url = api_base(tok) + "/servers?op=FIND&access_token=" + tok["access_token"]
    code, body = curl("POST", url, data={"projection": SERVER_PROJECTION, "include_all": True})
    try:
        env = json.loads(body)
    except Exception:
        die("servers?op=FIND returned non-JSON (HTTP %d):\n%s" % (code, body[:800]))
    if raw:
        print("=== servers?op=FIND HTTP %d ===\n%s\n" % (code, json.dumps(redact(env), indent=2, ensure_ascii=False)[:4000]))
    if not env.get("success", True):
        die("servers?op=FIND error: %s %s" % (env.get("code"), env.get("message")))
    result = env.get("result", env)
    cams = list(_walk_cameras(result))
    if not cams:
        die("No cameras found in the response. Re-run with --raw and share the (redacted) output so I can fix the parser.")
    return cams


def _walk_cameras(node, server=None):
    """Best-effort extraction of camera info from an unverified shape."""
    if isinstance(node, dict):
        looks_like_cam = ("id" in node and ("online" in node or "connected" in node)
                          and "cameras" not in node)
        if looks_like_cam:
            yield {
                "id": str(node.get("id")),
                "name": node.get("name") or "(no name)",
                "online": bool(node.get("online", node.get("connected"))),
                "width": node.get("width"),
                "height": node.get("height"),
                "video_codec": node.get("video_codec"),
                "audio_codec": node.get("audio_codec"),
                "server": server,
            }
        for k, v in node.items():
            yield from _walk_cameras(v, node.get("id", server) if k == "cameras" else server)
    elif isinstance(node, list):
        for x in node:
            yield from _walk_cameras(x, server)


def save_cameras(cams):
    """Write the camera list to .ivideon/camera.json for the Zig UI to read."""
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(CAMERA_FILE, "w", encoding="utf-8") as f:
        json.dump({"cameras": cams, "saved_at": int(time.time())}, f, ensure_ascii=False)


def live_url(tok, camera_id, q, host_override=None):
    base = host_override or api_base(tok)
    session = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(8))
    counter = int(time.monotonic() * 1000) & 0x7FFFFFFF
    return sign_url(
        base, "/cameras/%s/live_stream" % camera_id,
        [("q", str(q)), ("video_codecs", "h265,h264"), ("audio_codecs", "pcmu,pcma,aac,mp3")],
        tok["access_token"], tok.get("hmac_secret", ""), session, counter,
    )


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(description="Play an Ivideon camera on this PC.")
    p.add_argument("--email")
    p.add_argument("--camera", help="camera id; default is the only/first camera")
    p.add_argument("--q", type=int, default=1, choices=[0, 1, 2], help="quality 0=low 1=med 2=high")
    p.add_argument("--play", action="store_true", help="open the stream in ffplay")
    p.add_argument("--url", action="store_true", help="print the signed live URL and exit")
    p.add_argument("--host", help="override the stream host (e.g. https://streaming.ivideon.com)")
    p.add_argument("--raw", action="store_true", help="print redacted server responses")
    p.add_argument("--relogin", action="store_true", help="ignore the saved token and log in again")
    p.add_argument("--code", help="2FA code (from SMS/email) to finish a pending login")
    p.add_argument("--logout", action="store_true")
    args = p.parse_args()

    if args.logout:
        for f in (TOKEN_FILE, CHALLENGE_FILE):
            if os.path.exists(f):
                os.remove(f)
        print("Logged out (token removed).")
        return

    tok = None if (args.relogin or args.code) else load_token()
    if not tok:
        if args.code:
            tok = twofa_finish(args.code, raw=args.raw)
        else:
            email = args.email or os.environ.get("IVIDEON_EMAIL") or input("Ivideon email: ").strip()
            password = os.environ.get("IVIDEON_PASSWORD") or getpass.getpass("Ivideon password (hidden): ")
            res = login(email, password, raw=args.raw)
            if isinstance(res, dict) and res.get("_2fa"):
                twofa_begin(res["_2fa"], raw=args.raw)
                return
            tok = res

    cams = find_cameras(tok, raw=args.raw)
    save_cameras(cams)
    print("\nCameras:")
    for c in cams:
        print("  id=%-24s online=%-5s %s" % (c["id"], c["online"], c["name"]))

    if not (args.play or args.url):
        print("\nAdd --play to watch, or --url to print the stream link.")
        return

    cid = args.camera or (cams[0]["id"] if len(cams) == 1 else None)
    if not cid:
        die("Several cameras found — choose one with --camera <id>.")
    url = live_url(tok, cid, args.q, args.host)

    if args.url:
        print("\nSigned live URL (contains your token — keep it secret):\n" + url)
        return

    ffplay = shutil.which("ffplay") or _local_ffplay()
    if not ffplay:
        die("ffplay not found. Put ffplay.exe on PATH or in tools/ffmpeg/bin, or use --url with your own player.")
    print("\nOpening ffplay... (close the window to stop)")
    rc = subprocess.run([ffplay, "-loglevel", "warning", "-autoexit", "-window_title", "Ivideon %s" % cid, url]).returncode
    if rc != 0:
        print("\nffplay exited with %d. If it could not open the stream, the likely causes are:\n"
              "  * wrong stream host — try --host https://streaming.ivideon.com\n"
              "  * the server rejected the signature — re-run with --raw and share the output.\n" % rc)


def _local_ffplay():
    for base in ("ffmpeg/bin/ffplay.exe", "tools/ffmpeg/bin/ffplay.exe"):
        cand = os.path.join(os.path.dirname(os.path.abspath(__file__)), base)
        if os.path.exists(cand):
            return cand
    return None


if __name__ == "__main__":
    main()
