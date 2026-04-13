#!/usr/bin/env python3
"""BMC KVM interactive control via HTML5 iKVM viewer.

Extends bmc-kvm-screenshot.py with keyboard input capabilities.
Uses Playwright to automate the BMC's HTML5 KVM viewer (noVNC/InsydeVNC)
for screenshot capture and keystroke sending.

Prerequisites:
  - Python venv with playwright: .venv/bin/python (auto-detected)
  - Chromium: playwright install chromium

Commands:
  screenshot <output.png>              Capture KVM screenshot
  sendkeys <key1> [key2] ...           Send keyboard keys
  type <text>                          Type text string

Options for sendkeys/type:
  --wait MS              Wait MS milliseconds after each key (default: 100)
  --screenshot FILE      Capture screenshot after sending keys
  --post-wait MS         Wait MS milliseconds before screenshot (default: 500)
  --screenshot-each PFX  Capture after each key: PFX_001.png, PFX_002.png, ...
  --pre-screenshot       Also capture initial state as PFX_000.png

Key names follow Playwright convention:
  Letters/digits: a-z, 0-9
  Special: Enter, Escape, Tab, Backspace, Delete, Space
  Navigation: ArrowUp, ArrowDown, ArrowLeft, ArrowRight
  Function: F1-F12
  Modifiers: Shift, Control, Alt

Exit codes:
  0 = success
  1 = connection/auth failure
  2 = timeout
  3 = dependency error (playwright/chromium not installed)
"""
import argparse
import base64
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


# X11 keysym mapping for RFB protocol fallback
# Used when Playwright DOM events don't reach the VNC client
X11_KEYSYMS = {
    "Escape": 0xFF1B,
    "Tab": 0xFF09,
    "Backspace": 0xFF08,
    "Enter": 0xFF0D,
    "Delete": 0xFFFF,
    "Home": 0xFF50,
    "End": 0xFF57,
    "PageUp": 0xFF55,
    "PageDown": 0xFF56,
    "ArrowUp": 0xFF52,
    "ArrowDown": 0xFF54,
    "ArrowLeft": 0xFF51,
    "ArrowRight": 0xFF53,
    "F1": 0xFFBE,
    "F2": 0xFFBF,
    "F3": 0xFFC0,
    "F4": 0xFFC1,
    "F5": 0xFFC2,
    "F6": 0xFFC3,
    "F7": 0xFFC4,
    "F8": 0xFFC5,
    "F9": 0xFFC6,
    "F10": 0xFFC7,
    "F11": 0xFFC8,
    "F12": 0xFFC9,
    "Shift": 0xFFE1,
    "Control": 0xFFE3,
    "Alt": 0xFFE9,
    "Space": 0x0020,
    "+": 0x002B,
    "-": 0x002D,
}


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def bmc_login(bmc_ip, bmc_user, bmc_pass, timeout_sec):
    """Login to BMC and return SID cookie."""
    import http.cookiejar
    import ssl
    import urllib.parse
    import urllib.request

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
        return None

    for c in cj:
        if c.name == "SID":
            log(f"Login successful (SID: {c.value[:8]}...)")
            return c.value
    log("ERROR: Login failed - no SID cookie")
    return None


def setup_kvm_page(browser, bmc_ip, sid, timeout_sec):
    """Create browser context, set SID cookie, navigate to KVM, wait for canvas."""
    context = browser.new_context(
        ignore_https_errors=True,
        viewport={"width": 1280, "height": 1024},
    )
    page = context.new_page()

    context.add_cookies([
        {
            "name": "SID",
            "value": sid,
            "domain": bmc_ip,
            "path": "/",
        }
    ])

    kvm_url = (
        f"https://{bmc_ip}/cgi/url_redirect.cgi"
        f"?url_name=man_ikvm_html5_bootstrap"
    )
    log("Opening KVM viewer...")
    page.goto(kvm_url, wait_until="domcontentloaded", timeout=timeout_sec * 1000)

    log("Waiting for KVM canvas to render...")
    canvas_selector = "#noVNC_canvas"

    try:
        page.wait_for_selector(canvas_selector, timeout=timeout_sec * 1000)
    except Exception:
        log("ERROR: Canvas element not found")
        return None, None

    deadline = time.time() + timeout_sec
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
                break
            last_w, last_h = w, h
        time.sleep(1)

    if last_w <= 100 or last_h <= 100:
        log("ERROR: Canvas too small - KVM may not be connected")
        return None, None

    time.sleep(2)
    log(f"Canvas size: {last_w}x{last_h}")
    return page, context


def capture_canvas(page, output):
    """Capture canvas content and save as PNG."""
    log("Capturing canvas content...")
    data_url = page.evaluate(
        """() => {
            const c = document.getElementById('noVNC_canvas');
            return c.toDataURL('image/png');
        }"""
    )

    if not data_url or not data_url.startswith("data:image/png;base64,"):
        log("ERROR: Failed to capture canvas content")
        return 1

    png_data = base64.b64decode(data_url.split(",", 1)[1])

    output_dir = os.path.dirname(output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    if Image:
        import io
        img = Image.open(io.BytesIO(png_data))
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


def focus_canvas(page, safe_click=False, no_click=False):
    """Focus the noVNC canvas for keyboard input.

    If no_click is True, uses JavaScript focus() instead of clicking.
    If safe_click is True, clicks bottom-right corner to avoid menu items.
    Otherwise clicks center (default, proven to work for BIOS entry).
    """
    if no_click:
        page.evaluate(
            """() => {
                const c = document.getElementById('noVNC_canvas');
                if (c) {
                    c.setAttribute('tabindex', '0');
                    c.focus();
                    c.dispatchEvent(new Event('focus', {bubbles: true}));
                }
            }"""
        )
        # Also use Playwright's focus method as backup
        try:
            page.focus("#noVNC_canvas")
        except Exception:
            pass
        log("Canvas focused (no click, JS focus + tabindex)")
    elif safe_click:
        dims = page.evaluate(
            """() => {
                const c = document.getElementById('noVNC_canvas');
                return c ? {w: c.width, h: c.height} : {w: 800, h: 600};
            }"""
        )
        x = dims["w"] - 5
        y = dims["h"] - 5
        page.click("#noVNC_canvas", position={"x": x, "y": y})
        log(f"Canvas focused (safe click at {x},{y})")
    else:
        page.click("#noVNC_canvas")
        log("Canvas focused (center click)")
    time.sleep(0.2)


def detect_rfb_client(page):
    """Detect the RFB/VNC client object for direct key injection."""
    rfb_obj = page.evaluate(
        """() => {
            // InsydeVNC uses a global rfb object
            if (typeof rfb !== 'undefined' && rfb && typeof rfb.sendKey === 'function') {
                return 'rfb';
            }
            // noVNC uses RFB class
            if (typeof document.__pointer !== 'undefined') {
                return 'noVNC';
            }
            // Try to find it in window
            if (window.rfb && typeof window.rfb.sendKey === 'function') {
                return 'window.rfb';
            }
            // Supermicro iKVM: UI.rfb holds the RFB instance
            if (typeof UI !== 'undefined' && UI.rfb && typeof UI.rfb.sendKey === 'function') {
                return 'UI.rfb';
            }
            // Search for VNC display object
            var scripts = document.getElementsByTagName('script');
            for (var i = 0; i < scripts.length; i++) {
                if (scripts[i].src && scripts[i].src.indexOf('rfb') >= 0) {
                    return 'rfb_script_found';
                }
            }
            return null;
        }"""
    )
    log(f"RFB client detection: {rfb_obj}")
    return rfb_obj


def send_key_playwright(page, key):
    """Send a key using Playwright's keyboard API."""
    page.keyboard.press(key)


def send_key_rfb(page, key, rfb_obj_name):
    """Send a key using RFB protocol direct injection."""
    keysym = X11_KEYSYMS.get(key)
    if keysym is None:
        if len(key) == 1:
            keysym = ord(key)
        else:
            log(f"WARNING: No keysym mapping for '{key}', falling back to Playwright")
            return False

    js_code = f"""() => {{
        var obj = {rfb_obj_name};
        if (obj && typeof obj.sendKey === 'function') {{
            obj.sendKey({keysym}, true);
            obj.sendKey({keysym}, false);
            return true;
        }}
        return false;
    }}"""
    result = page.evaluate(js_code)
    return result


def send_keys(page, keys, wait_ms, rfb_obj_name=None,
              screenshot_each_prefix=None, post_wait_ms=500,
              safe_click=False, no_click=False):
    """Send a sequence of keys with delay between each.

    If screenshot_each_prefix is set, capture a screenshot after each key
    as PREFIX_001.png, PREFIX_002.png, etc.
    """
    focus_canvas(page, safe_click=safe_click, no_click=no_click)

    for i, key in enumerate(keys, 1):
        log(f"Sending key [{i}/{len(keys)}]: {key}")

        sent = False
        if rfb_obj_name and rfb_obj_name in ("rfb", "window.rfb", "UI.rfb"):
            sent = send_key_rfb(page, key, rfb_obj_name)
            if sent:
                log(f"  -> sent via RFB ({rfb_obj_name})")

        if not sent:
            send_key_playwright(page, key)
            log(f"  -> sent via Playwright keyboard")

        time.sleep(wait_ms / 1000.0)

        if screenshot_each_prefix:
            time.sleep(post_wait_ms / 1000.0)
            outfile = f"{screenshot_each_prefix}_{i:03d}.png"
            capture_canvas(page, outfile)


def send_text(page, text, wait_ms, rfb_obj_name=None):
    """Type a text string character by character."""
    focus_canvas(page)

    for ch in text:
        log(f"Typing: '{ch}'")

        sent = False
        if rfb_obj_name and rfb_obj_name in ("rfb", "window.rfb", "UI.rfb"):
            keysym = ord(ch)
            js_code = f"""() => {{
                var obj = {rfb_obj_name};
                if (obj && typeof obj.sendKey === 'function') {{
                    obj.sendKey({keysym}, true);
                    obj.sendKey({keysym}, false);
                    return true;
                }}
                return false;
            }}"""
            sent = page.evaluate(js_code)

        if not sent:
            page.keyboard.type(ch)

        time.sleep(wait_ms / 1000.0)


def cmd_screenshot(args):
    """Handle screenshot command."""
    sid = bmc_login(args.bmc_ip, args.bmc_user, args.bmc_pass, args.timeout)
    if not sid:
        return 1

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=["--ignore-certificate-errors", "--no-sandbox", "--disable-gpu"],
        )
        page, context = setup_kvm_page(browser, args.bmc_ip, sid, args.timeout)
        if not page:
            browser.close()
            return 1

        rc = capture_canvas(page, args.output)
        browser.close()
        return rc


def cmd_sendkeys(args):
    """Handle sendkeys command."""
    sid = bmc_login(args.bmc_ip, args.bmc_user, args.bmc_pass, args.timeout)
    if not sid:
        return 1

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=["--ignore-certificate-errors", "--no-sandbox", "--disable-gpu"],
        )
        page, context = setup_kvm_page(browser, args.bmc_ip, sid, args.timeout)
        if not page:
            browser.close()
            return 1

        rfb_obj = detect_rfb_client(page)

        screenshot_each = getattr(args, "screenshot_each", None)

        if getattr(args, "pre_screenshot", False) and screenshot_each:
            outfile = f"{screenshot_each}_000.png"
            log("Capturing pre-screenshot...")
            capture_canvas(page, outfile)

        send_keys(page, args.keys, args.wait, rfb_obj,
                  screenshot_each_prefix=screenshot_each,
                  post_wait_ms=args.post_wait,
                  safe_click=getattr(args, "safe_click", False),
                  no_click=getattr(args, "no_click", False))

        rc = 0
        if args.screenshot:
            time.sleep(args.post_wait / 1000.0)
            rc = capture_canvas(page, args.screenshot)

        browser.close()
        return rc


def cmd_type(args):
    """Handle type command."""
    sid = bmc_login(args.bmc_ip, args.bmc_user, args.bmc_pass, args.timeout)
    if not sid:
        return 1

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=["--ignore-certificate-errors", "--no-sandbox", "--disable-gpu"],
        )
        page, context = setup_kvm_page(browser, args.bmc_ip, sid, args.timeout)
        if not page:
            browser.close()
            return 1

        rfb_obj = detect_rfb_client(page)
        send_text(page, args.text, args.wait, rfb_obj)

        rc = 0
        if args.screenshot:
            time.sleep(args.post_wait / 1000.0)
            rc = capture_canvas(page, args.screenshot)

        browser.close()
        return rc


def main():
    parser = argparse.ArgumentParser(
        description="BMC KVM interactive control via HTML5 iKVM viewer"
    )
    parser.add_argument("--bmc-ip", required=True, help="BMC IP address")
    parser.add_argument("--bmc-user", required=True, help="BMC username")
    parser.add_argument("--bmc-pass", required=True, help="BMC password")
    parser.add_argument(
        "--timeout", type=int, default=30,
        help="Connection timeout in seconds (default: 30)",
    )

    subparsers = parser.add_subparsers(dest="command", help="Command to execute")
    subparsers.required = True

    # screenshot command
    p_screenshot = subparsers.add_parser("screenshot", help="Capture KVM screenshot")
    p_screenshot.add_argument("output", help="Output PNG file path")

    # sendkeys command
    p_sendkeys = subparsers.add_parser("sendkeys", help="Send keyboard keys")
    p_sendkeys.add_argument("keys", nargs="+", help="Key names to send")
    p_sendkeys.add_argument(
        "--wait", type=int, default=100,
        help="Wait between keys in ms (default: 100)",
    )
    p_sendkeys.add_argument(
        "--screenshot", metavar="FILE",
        help="Capture screenshot after sending keys",
    )
    p_sendkeys.add_argument(
        "--post-wait", type=int, default=500,
        help="Wait before screenshot in ms (default: 500)",
    )
    p_sendkeys.add_argument(
        "--screenshot-each", metavar="PREFIX",
        help="Capture screenshot after each key as PREFIX_001.png, PREFIX_002.png, ...",
    )
    p_sendkeys.add_argument(
        "--pre-screenshot", action="store_true",
        help="Capture initial state as PREFIX_000.png (requires --screenshot-each)",
    )
    p_sendkeys.add_argument(
        "--safe-click", action="store_true",
        help="Click bottom-right corner instead of center to avoid moving BIOS cursor",
    )
    p_sendkeys.add_argument(
        "--no-click", action="store_true",
        help="Use JS focus() instead of clicking canvas (no mouse event sent to remote)",
    )

    # type command
    p_type = subparsers.add_parser("type", help="Type text string")
    p_type.add_argument("text", help="Text to type")
    p_type.add_argument(
        "--wait", type=int, default=50,
        help="Wait between characters in ms (default: 50)",
    )
    p_type.add_argument(
        "--screenshot", metavar="FILE",
        help="Capture screenshot after typing",
    )
    p_type.add_argument(
        "--post-wait", type=int, default=500,
        help="Wait before screenshot in ms (default: 500)",
    )

    args = parser.parse_args()

    if args.command == "screenshot":
        rc = cmd_screenshot(args)
    elif args.command == "sendkeys":
        rc = cmd_sendkeys(args)
    elif args.command == "type":
        rc = cmd_type(args)
    else:
        parser.print_help()
        rc = 1

    sys.exit(rc)


if __name__ == "__main__":
    main()
