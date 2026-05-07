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


def detect_vkbd(page):
    """Detect VirtualKeyboard-style key sending mechanism on Supermicro iKVM.

    Returns a dict with capabilities (truthy) or None if no VKbd-style
    machinery is available. The Supermicro iKVM HTML5 viewer exposes
    UI.rfb.sendMacro() which is what the on-screen Hot Key buttons call;
    it constructs a full key-down + key-up wire sequence (and supports
    modifier combos), so it is more robust than sendKey() for special
    keys like F2/F11/Delete.

    Note: All UI.rfb.send* functions short-circuit when
    UI.rfb._rfb_state !== "normal" or _view_only is true. Callers must
    wait for the connection to reach 'normal' state before sending.
    """
    info = page.evaluate(
        """() => {
            const out = {};
            if (typeof UI === 'undefined' || !UI.rfb) return out;
            out.has_sendMacro = typeof UI.rfb.sendMacro === 'function';
            out.has_sendKey = typeof UI.rfb.sendKey === 'function';
            out.sendKey_arity = out.has_sendKey ? UI.rfb.sendKey.length : 0;
            out.has_sendKeyHold = typeof UI.rfb.sendKeyHold === 'function';
            out.rfb_state = UI.rfb._rfb_state;
            out.insydevnc = !!UI.rfb._rfb_insydevnc;
            out.view_only = !!UI.rfb._view_only;
            return out;
        }"""
    )
    if not info or not info.get("has_sendMacro"):
        log(f"VKbd detection: not available ({info})")
        return None
    log(f"VKbd detection: sendMacro available, sendKey arity={info.get('sendKey_arity')}, "
        f"insydevnc={info.get('insydevnc')}, state={info.get('rfb_state')}")
    return info


def wait_rfb_normal(page, timeout_sec=5):
    """Poll UI.rfb._rfb_state until it becomes 'normal' or timeout. Returns final state."""
    deadline = time.time() + timeout_sec
    last = None
    while time.time() < deadline:
        last = page.evaluate(
            "() => (typeof UI !== 'undefined' && UI.rfb) ? UI.rfb._rfb_state : null"
        )
        if last == "normal":
            return last
        time.sleep(0.1)
    return last


def send_key_playwright(page, key):
    """Send a key using Playwright's keyboard API."""
    page.keyboard.press(key)


def send_key_rfb(page, key, rfb_obj_name):
    """Send a key using RFB protocol direct injection.

    Note: UI.rfb.sendKey returns false silently if _rfb_state !== "normal"
    or _view_only is set, so a True return here indicates only that
    sendKey() was called and reported success — not necessarily that the
    key reached the remote.
    """
    keysym = X11_KEYSYMS.get(key)
    if keysym is None:
        if len(key) == 1:
            keysym = ord(key)
        else:
            log(f"WARNING: No keysym mapping for '{key}', falling back to Playwright")
            return False

    js_code = f"""() => {{
        var obj = {rfb_obj_name};
        if (!obj || typeof obj.sendKey !== 'function') return false;
        if (obj._rfb_state !== undefined && obj._rfb_state !== 'normal') return false;
        var r1 = obj.sendKey({keysym}, true);
        var r2 = obj.sendKey({keysym}, false);
        return (r1 !== false) && (r2 !== false);
    }}"""
    result = page.evaluate(js_code)
    return result


def send_key_vkbd(page, key, vkbd_info):
    """Send a key via UI.rfb.sendMacro (Supermicro iKVM Hot Key mechanism).

    sendMacro builds a full down+up sequence and uses keyEventInsyde
    encoding on InsydeVNC firmware (where the Supermicro KVM lives).
    Returns False if the RFB state is not 'normal' (silent no-op
    otherwise) so callers know to fall back.
    """
    keysym = X11_KEYSYMS.get(key)
    if keysym is None:
        if len(key) == 1:
            keysym = ord(key)
        else:
            return False

    js = f"""() => {{
        if (typeof UI === 'undefined' || !UI.rfb) {{
            return {{ok: false, reason: 'no UI.rfb'}};
        }}
        if (UI.rfb._rfb_state !== 'normal') {{
            return {{ok: false, reason: 'state=' + UI.rfb._rfb_state}};
        }}
        if (UI.rfb._view_only) {{
            return {{ok: false, reason: 'view_only'}};
        }}
        if (typeof UI.rfb.sendMacro !== 'function') {{
            return {{ok: false, reason: 'no sendMacro'}};
        }}
        try {{
            var r = UI.rfb.sendMacro([{keysym}]);
            return {{ok: r !== false}};
        }} catch (e) {{
            return {{ok: false, reason: String(e)}};
        }}
    }}"""
    res = page.evaluate(js)
    if not res or not res.get("ok"):
        log(f"  [vkbd] not delivered: {res}")
        return False
    return True


def send_keys(page, keys, wait_ms, rfb_obj_name=None, vkbd_info=None,
              prefer="auto", screenshot_each_prefix=None, post_wait_ms=500,
              safe_click=False, no_click=False):
    """Send a sequence of keys with delay between each.

    Path priority by --prefer:
      auto / vkbd: vkbd (sendMacro) > rfb (sendKey) > playwright
      rfb:         rfb > vkbd > playwright
      playwright:  playwright only

    The vkbd path uses UI.rfb.sendMacro which is more robust on Supermicro
    iKVM HTML5 viewers (InsydeVNC) than direct DOM key events because it
    bypasses canvas focus / keymap translation issues. Both vkbd and rfb
    short-circuit when _rfb_state !== "normal", so this routine waits for
    the RFB connection to reach 'normal' state before the first send.

    If screenshot_each_prefix is set, capture a screenshot after each key
    as PREFIX_001.png, PREFIX_002.png, etc.
    """
    focus_canvas(page, safe_click=safe_click, no_click=no_click)

    if vkbd_info or rfb_obj_name in ("rfb", "window.rfb", "UI.rfb"):
        state = wait_rfb_normal(page, timeout_sec=5)
        log(f"RFB state before sending: {state}")

    order = {
        "auto":       ["vkbd", "rfb", "playwright"],
        "vkbd":       ["vkbd", "rfb", "playwright"],
        "rfb":        ["rfb", "vkbd", "playwright"],
        "playwright": ["playwright"],
    }.get(prefer, ["vkbd", "rfb", "playwright"])

    for i, key in enumerate(keys, 1):
        log(f"Sending key [{i}/{len(keys)}]: {key}")

        sent = False
        for path in order:
            if path == "vkbd" and vkbd_info:
                if send_key_vkbd(page, key, vkbd_info):
                    log("  -> sent via vkbd (UI.rfb.sendMacro)")
                    sent = True
                    break
            elif path == "rfb" and rfb_obj_name in ("rfb", "window.rfb", "UI.rfb"):
                if send_key_rfb(page, key, rfb_obj_name):
                    log(f"  -> sent via rfb ({rfb_obj_name}.sendKey)")
                    sent = True
                    break
            elif path == "playwright":
                send_key_playwright(page, key)
                log("  -> sent via playwright keyboard")
                sent = True
                break

        if not sent:
            log(f"  WARNING: key '{key}' not delivered by any path")

        time.sleep(wait_ms / 1000.0)

        if screenshot_each_prefix:
            time.sleep(post_wait_ms / 1000.0)
            outfile = f"{screenshot_each_prefix}_{i:03d}.png"
            capture_canvas(page, outfile)


def send_text(page, text, wait_ms, rfb_obj_name=None, vkbd_info=None, prefer="auto"):
    """Type a text string character by character.

    Uses the same path priority as send_keys: vkbd (sendMacro) > rfb > playwright.
    """
    focus_canvas(page)

    if vkbd_info or rfb_obj_name in ("rfb", "window.rfb", "UI.rfb"):
        state = wait_rfb_normal(page, timeout_sec=5)
        log(f"RFB state before sending: {state}")

    order = {
        "auto":       ["vkbd", "rfb", "playwright"],
        "vkbd":       ["vkbd", "rfb", "playwright"],
        "rfb":        ["rfb", "vkbd", "playwright"],
        "playwright": ["playwright"],
    }.get(prefer, ["vkbd", "rfb", "playwright"])

    for ch in text:
        log(f"Typing: '{ch}'")

        sent = False
        for path in order:
            if path == "vkbd" and vkbd_info:
                if send_key_vkbd(page, ch, vkbd_info):
                    sent = True
                    break
            elif path == "rfb" and rfb_obj_name in ("rfb", "window.rfb", "UI.rfb"):
                if send_key_rfb(page, ch, rfb_obj_name):
                    sent = True
                    break
            elif path == "playwright":
                page.keyboard.type(ch)
                sent = True
                break

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
        vkbd_info = detect_vkbd(page)

        screenshot_each = getattr(args, "screenshot_each", None)

        if getattr(args, "pre_screenshot", False) and screenshot_each:
            outfile = f"{screenshot_each}_000.png"
            log("Capturing pre-screenshot...")
            capture_canvas(page, outfile)

        send_keys(page, args.keys, args.wait, rfb_obj, vkbd_info=vkbd_info,
                  prefer=getattr(args, "prefer", "auto"),
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
        vkbd_info = detect_vkbd(page)
        send_text(page, args.text, args.wait, rfb_obj, vkbd_info=vkbd_info,
                  prefer=getattr(args, "prefer", "auto"))

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
    p_sendkeys.add_argument(
        "--prefer", choices=["auto", "vkbd", "rfb", "playwright"], default="auto",
        help="Key injection path priority (default: auto = vkbd > rfb > playwright). "
             "vkbd uses UI.rfb.sendMacro (Supermicro Hot Key path, recommended for "
             "BIOS/POST navigation). rfb uses UI.rfb.sendKey. playwright sends DOM "
             "key events to the browser canvas.",
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
    p_type.add_argument(
        "--prefer", choices=["auto", "vkbd", "rfb", "playwright"], default="auto",
        help="Key injection path priority (default: auto = vkbd > rfb > playwright)",
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
