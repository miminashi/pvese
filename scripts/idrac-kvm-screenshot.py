#!/usr/bin/env python3
"""iDRAC7 KVM screenshot capture via capconsole API.

Uses iDRAC7's built-in console preview API (capconsole/scapture0.png)
to capture the server's video output as a PNG image. No browser needed.

Authentication flow:
  1. POST /data/login  -> get session cookie + ST2 token
  2. GET /data?get=consolepreview[auto {ts}]  -> trigger preview refresh
     (uses session cookie + ST2 as HTTP header)
  3. GET /capconsole/scapture0.png?{ts}       -> download PNG
     (uses session cookie + -ST2 as cookie)

Output: 400x300 thumbnail PNG (5-color grayscale).

Exit codes:
  0 = success
  1 = auth failure
  2 = screenshot capture failure
"""
import argparse
import os
import re
import ssl
import sys
import time
import http.cookiejar
import urllib.request
import urllib.parse


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def make_ssl_context():
    """Create SSL context that ignores cert errors."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def idrac_login(ssl_ctx, bmc_ip, user, password, timeout):
    """Login to iDRAC7 and return (session_cookie, st2_token) tuple."""
    url = f"https://{bmc_ip}/data/login"
    data = urllib.parse.urlencode({"user": user, "password": password}).encode()

    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(cj),
        urllib.request.HTTPSHandler(context=ssl_ctx),
    )

    try:
        resp = opener.open(url, data, timeout=timeout)
        body = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        log(f"ERROR: Login request failed: {e}")
        return None, None

    auth_match = re.search(r"<authResult>(\d+)</authResult>", body)
    if not auth_match or auth_match.group(1) != "0":
        auth_val = auth_match.group(1) if auth_match else "not found"
        log(f"ERROR: Authentication failed (authResult={auth_val})")
        return None, None

    session_cookie = None
    for c in cj:
        session_cookie = f"{c.name}={c.value}"
        break

    st2_match = re.search(r"ST2=([^<\"&\s,]+)", body)
    if not st2_match:
        log("ERROR: ST2 token not found in login response")
        return None, None

    st2 = st2_match.group(1)
    log(f"Login OK (ST2: {st2[:8]}...)")
    return session_cookie, st2


def idrac_screenshot(ssl_ctx, bmc_ip, session_cookie, st2, output, timeout):
    """Capture screenshot via capconsole API with preview trigger.

    Two different auth mechanisms are used:
    - /data endpoint: session cookie + ST2 as HTTP header
    - /capconsole:    session cookie + -ST2 as cookie value
    """
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ssl_ctx),
    )

    # Step 1: Trigger console preview refresh
    ts = str(int(time.time() * 1000))
    preview_url = f"https://{bmc_ip}/data?get=consolepreview[auto%20{ts}]"
    req = urllib.request.Request(preview_url)
    req.add_header("Cookie", session_cookie)
    req.add_header("ST2", st2)

    try:
        resp = opener.open(req, timeout=timeout)
        resp.read()
    except Exception as e:
        log(f"WARNING: Preview trigger failed: {e}")

    # Step 2: Brief delay for preview to update
    time.sleep(1)

    # Step 3: Fetch the screenshot PNG
    ts2 = str(int(time.time() * 1000))
    png_url = f"https://{bmc_ip}/capconsole/scapture0.png?{ts2}"
    req = urllib.request.Request(png_url)
    req.add_header("Cookie", f"{session_cookie}; -ST2={st2}")

    try:
        resp = opener.open(req, timeout=timeout)
        png_data = resp.read()
    except urllib.error.HTTPError as e:
        log(f"ERROR: Screenshot request failed: HTTP {e.code}")
        return 2
    except Exception as e:
        log(f"ERROR: Screenshot request failed: {e}")
        return 2

    if len(png_data) < 100:
        log(f"ERROR: Screenshot too small ({len(png_data)} bytes)")
        return 2

    if png_data[:4] != b"\x89PNG":
        log(f"ERROR: Response is not a PNG image")
        return 2

    output_dir = os.path.dirname(output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    with open(output, "wb") as f:
        f.write(png_data)

    log(f"Screenshot saved: {output} ({len(png_data)} bytes)")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="iDRAC7 KVM screenshot capture via capconsole API"
    )
    parser.add_argument("--bmc-ip", required=True, help="iDRAC IP address")
    parser.add_argument("--bmc-user", required=True, help="iDRAC username")
    parser.add_argument("--bmc-pass", required=True, help="iDRAC password")
    parser.add_argument("--output", required=True, help="Output PNG file path")
    parser.add_argument(
        "--timeout", type=int, default=30, help="Timeout in seconds (default: 30)"
    )
    args = parser.parse_args()

    ssl_ctx = make_ssl_context()
    session_cookie, st2 = idrac_login(
        ssl_ctx, args.bmc_ip, args.bmc_user, args.bmc_pass, args.timeout
    )
    if st2 is None:
        sys.exit(1)

    rc = idrac_screenshot(
        ssl_ctx, args.bmc_ip, session_cookie, st2, args.output, args.timeout
    )
    sys.exit(rc)


if __name__ == "__main__":
    main()
