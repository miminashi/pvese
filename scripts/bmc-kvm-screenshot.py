#!/usr/bin/env python3
"""BMC KVM screenshot capture via HTML5 iKVM viewer.

Uses Playwright to automate the BMC's HTML5 KVM viewer (noVNC/AST2100)
and capture the screen as a PNG image.

Prerequisites:
  - Python venv with playwright: .venv/bin/python (auto-detected)
  - Chromium: playwright install chromium

Exit codes:
  0 = success
  1 = connection/auth failure
  2 = timeout
  3 = dependency error (playwright/chromium not installed)
"""
import argparse
import os
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

try:
    from PIL import Image
except ImportError:
    Image = None


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def capture_screenshot(bmc_ip, bmc_user, bmc_pass, output, timeout_sec):
    """Capture KVM screenshot using Playwright."""
    kvm_url = (
        f"https://{bmc_ip}/cgi/url_redirect.cgi"
        f"?url_name=man_ikvm_html5_bootstrap"
    )

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=[
                "--ignore-certificate-errors",
                "--no-sandbox",
                "--disable-gpu",
            ],
        )
        context = browser.new_context(
            ignore_https_errors=True,
            viewport={"width": 1280, "height": 1024},
        )
        page = context.new_page()

        # Step 1: Login to BMC via HTTP to get SID cookie
        log(f"Logging in to BMC at {bmc_ip}")
        import http.cookiejar
        import ssl
        import urllib.request
        import urllib.parse

        ssl_ctx = ssl.create_default_context()
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = ssl.CERT_NONE
        cj = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(cj),
            urllib.request.HTTPSHandler(context=ssl_ctx),
        )
        login_data = urllib.parse.urlencode(
            {"name": bmc_user, "pwd": bmc_pass}
        ).encode()
        try:
            resp = opener.open(
                f"https://{bmc_ip}/cgi/login.cgi",
                login_data,
                timeout=timeout_sec,
            )
            resp.read()
        except Exception as e:
            log(f"ERROR: Login request failed: {e}")
            browser.close()
            return 1

        sid = None
        for c in cj:
            if c.name == "SID":
                sid = c.value
        if not sid:
            log("ERROR: Login failed - no SID cookie")
            browser.close()
            return 1

        log(f"Login successful (SID: {sid[:8]}...)")

        # Set the SID cookie in the browser context
        context.add_cookies([
            {
                "name": "SID",
                "value": sid,
                "domain": bmc_ip,
                "path": "/",
            }
        ])

        # Step 2: Navigate to KVM viewer
        log("Opening KVM viewer...")
        page.goto(kvm_url, wait_until="domcontentloaded", timeout=timeout_sec * 1000)

        # Step 3: Wait for canvas to have content
        log("Waiting for KVM canvas to render...")
        canvas_selector = "#noVNC_canvas"

        try:
            page.wait_for_selector(canvas_selector, timeout=timeout_sec * 1000)
        except Exception:
            log("ERROR: Canvas element not found")
            browser.close()
            return 1

        # Wait for the canvas to get a reasonable size (KVM connected)
        deadline = time.time() + timeout_sec
        canvas_ready = False
        last_w, last_h = 0, 0

        while time.time() < deadline:
            dims = page.evaluate(
                """() => {
                    const c = document.getElementById('noVNC_canvas');
                    return c ? {w: c.width, h: c.height} : {w: 0, h: 0};
                }"""
            )
            w, h = dims["w"], dims["h"]
            if w > 100 and h > 100:
                if w == last_w and h == last_h:
                    canvas_ready = True
                    break
                last_w, last_h = w, h
            time.sleep(1)

        if not canvas_ready:
            log(f"WARNING: Canvas size unstable ({last_w}x{last_h}), proceeding anyway")
            if last_w <= 100 or last_h <= 100:
                log("ERROR: Canvas too small - KVM may not be connected")
                browser.close()
                return 2

        # Extra wait for rendering to stabilize
        time.sleep(2)

        # Step 4: Get final canvas dimensions
        dims = page.evaluate(
            """() => {
                const c = document.getElementById('noVNC_canvas');
                return {w: c.width, h: c.height};
            }"""
        )
        log(f"Canvas size: {dims['w']}x{dims['h']}")

        # Step 5: Extract canvas as PNG via toDataURL
        log("Capturing canvas content...")
        data_url = page.evaluate(
            """() => {
                const c = document.getElementById('noVNC_canvas');
                return c.toDataURL('image/png');
            }"""
        )

        browser.close()

        if not data_url or not data_url.startswith("data:image/png;base64,"):
            log("ERROR: Failed to capture canvas content")
            return 1

        # Decode base64 PNG
        import base64

        png_data = base64.b64decode(data_url.split(",", 1)[1])

        # Crop out any toolbar/padding if needed
        if Image:
            import io

            img = Image.open(io.BytesIO(png_data))
            # Check if image is mostly black (no signal)
            if img.size[0] > 0 and img.size[1] > 0:
                img.save(output, "PNG")
                log(f"Screenshot saved: {output} ({img.size[0]}x{img.size[1]})")
            else:
                with open(output, "wb") as f:
                    f.write(png_data)
                log(f"Screenshot saved: {output}")
        else:
            with open(output, "wb") as f:
                f.write(png_data)
            log(f"Screenshot saved: {output}")

        return 0


def main():
    parser = argparse.ArgumentParser(
        description="BMC KVM screenshot capture via HTML5 iKVM viewer"
    )
    parser.add_argument("--bmc-ip", required=True, help="BMC IP address")
    parser.add_argument("--bmc-user", required=True, help="BMC username")
    parser.add_argument("--bmc-pass", required=True, help="BMC password")
    parser.add_argument("--output", required=True, help="Output PNG file path")
    parser.add_argument(
        "--timeout",
        type=int,
        default=30,
        help="Timeout in seconds (default: 30)",
    )
    args = parser.parse_args()

    output_dir = os.path.dirname(args.output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    rc = capture_screenshot(
        args.bmc_ip, args.bmc_user, args.bmc_pass, args.output, args.timeout
    )
    sys.exit(rc)


if __name__ == "__main__":
    main()
