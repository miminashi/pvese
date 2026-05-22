#!/usr/bin/env python3
"""Fujitsu iRMC S4 HTML5 KVM screenshot capture.

Login flow (verified on TX1320 M3 / iRMC S4 FW 9.08F):
  1. GET https://<bmc>/ with HTTP Basic Auth -> /login form (only "P99" submit button)
  2. POST the form (P99=Login) -> session URL contains ?sid=<SID>
     - iRMC does NOT use cookies; SID is carried as a URL query parameter
  3. GET https://<bmc>/viewer.html?sid=<SID> -> KVM viewer page
  4. Wait for <canvas id="kvm"> to be present and the WebSocket wss://<bmc>/kvm to be open
  5. canvas.toDataURL('image/png') -> base64 PNG

Exit codes:
  0 = success
  1 = connection / auth / runtime failure
  2 = canvas timeout (KVM did not initialize)
  3 = playwright not installed
"""
import argparse
import base64
import os
import re
import sys
import time

VENV_PYTHON = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ".venv", "bin", "python"
)

if os.path.exists(VENV_PYTHON) and sys.executable != VENV_PYTHON:
    os.execv(VENV_PYTHON, [VENV_PYTHON] + sys.argv)

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print(
        "ERROR: playwright not installed.\n"
        "  uv venv .venv && uv pip install --python .venv/bin/python playwright\n"
        "  .venv/bin/playwright install chromium",
        file=sys.stderr,
    )
    sys.exit(3)


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def login_and_get_sid(page, bmc_ip, timeout_sec):
    """Visit / and submit the login form. Returns SID extracted from the URL."""
    log(f"Logging in to iRMC at {bmc_ip}")
    page.goto(f"https://{bmc_ip}/", wait_until="networkidle",
              timeout=timeout_sec * 1000)
    # The login page contains a single submit button named P99.
    page.click('input[name="P99"]', timeout=timeout_sec * 1000)
    page.wait_for_load_state("networkidle", timeout=timeout_sec * 1000)
    m = re.search(r'sid=([^&#]+)', page.url)
    if not m:
        raise RuntimeError(f"Login did not yield SID in URL: {page.url}")
    sid = m.group(1)
    log(f"Login successful (SID: {sid[:8]}...)")
    return sid


def capture_canvas(viewer_page, output, timeout_sec):
    """Wait for <canvas id="kvm"> to appear and capture it as PNG."""
    log("Waiting for KVM canvas...")
    try:
        viewer_page.wait_for_selector("canvas#kvm",
                                      timeout=timeout_sec * 1000)
    except Exception as e:
        raise RuntimeError(f"canvas#kvm not found within {timeout_sec}s: {e}")

    # Wait until canvas has class "alive" (set by viewer.min.js once WS handshake completes)
    # and reasonable dimensions.
    deadline = time.time() + timeout_sec
    last_w = last_h = 0
    stable_for = 0.0
    last_check = time.time()
    while time.time() < deadline:
        info = viewer_page.evaluate(
            """() => {
                const c = document.getElementById('kvm');
                if (!c) return {w: 0, h: 0, alive: false};
                return {w: c.width, h: c.height,
                        alive: c.classList.contains('alive')};
            }"""
        )
        w, h, alive = info["w"], info["h"], info["alive"]
        now = time.time()
        if alive and w > 100 and h > 100 and w == last_w and h == last_h:
            stable_for += now - last_check
            if stable_for >= 2.0:
                break
        else:
            stable_for = 0.0
        last_w, last_h = w, h
        last_check = now
        time.sleep(0.5)
    log(f"Canvas: {last_w}x{last_h} alive={alive}")
    if last_w <= 100 or last_h <= 100:
        raise TimeoutError(
            f"Canvas dimensions stayed at {last_w}x{last_h} — KVM did not initialize"
        )

    # Extract canvas content via toDataURL (works on tainted canvases too because
    # iRMC viewer draws same-origin pixel data).
    data_url = viewer_page.evaluate(
        """() => {
            const c = document.getElementById('kvm');
            return c.toDataURL('image/png');
        }"""
    )
    if not data_url or not data_url.startswith("data:image/png;base64,"):
        raise RuntimeError("Failed to extract canvas as data URL")

    png = base64.b64decode(data_url.split(",", 1)[1])
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    with open(output, "wb") as f:
        f.write(png)
    log(f"Saved {output} ({len(png)} bytes, {last_w}x{last_h})")


def capture(bmc_ip, bmc_user, bmc_pass, output, timeout_sec, headless=True):
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=headless,
            args=[
                "--ignore-certificate-errors",
                "--no-sandbox",
                "--disable-gpu",
            ],
        )
        try:
            context = browser.new_context(
                ignore_https_errors=True,
                http_credentials={"username": bmc_user, "password": bmc_pass},
                viewport={"width": 1280, "height": 1024},
            )
            page = context.new_page()
            sid = login_and_get_sid(page, bmc_ip, timeout_sec)

            # Open the KVM viewer in a new page (the menu uses popup, but
            # we just open the same URL directly).
            viewer_url = f"https://{bmc_ip}/viewer.html?ms=0&lang=0&sid={sid}"
            log(f"Opening viewer: {viewer_url}")
            viewer_page = context.new_page()
            viewer_page.goto(viewer_url, wait_until="load",
                             timeout=timeout_sec * 1000)
            capture_canvas(viewer_page, output, timeout_sec)
        finally:
            browser.close()


def main():
    parser = argparse.ArgumentParser(
        description="iRMC S4 HTML5 KVM screenshot capture"
    )
    parser.add_argument("--bmc-ip", required=True)
    parser.add_argument("--bmc-user", required=True)
    parser.add_argument("--bmc-pass", required=True)
    parser.add_argument("--output", required=True, help="PNG output path")
    parser.add_argument("--timeout", type=int, default=30,
                        help="Per-step timeout seconds (default 30)")
    parser.add_argument("--headless", action="store_true", default=True)
    parser.add_argument("--no-headless", dest="headless", action="store_false")
    args = parser.parse_args()

    try:
        capture(args.bmc_ip, args.bmc_user, args.bmc_pass,
                args.output, args.timeout, headless=args.headless)
    except TimeoutError as e:
        log(f"TIMEOUT: {e}")
        sys.exit(2)
    except Exception as e:
        log(f"ERROR: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
