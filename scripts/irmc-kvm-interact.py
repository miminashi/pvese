#!/usr/bin/env python3
"""Fujitsu iRMC S4 HTML5 KVM interactive control.

Extends irmc-kvm-screenshot.py with keyboard input via Playwright.

Login flow is the same as irmc-kvm-screenshot.py:
  /login -> POST P99=Login -> SID in URL -> /viewer.html?sid=<SID>

Capture modes (--capture-mode):
  locator (default) : viewer_page.locator("canvas#kvm").screenshot(path=...)
                       — Uses Playwright's element screenshot, which captures
                         the composed display frame (resilient to WebGL
                         preserveDrawingBuffer:false canvases that return
                         black via toDataURL()).
  canvas            : canvas#kvm.toDataURL("image/png") (legacy path)
                       — Kept as fallback; returns black if the viewer's
                         canvas is WebGL with preserveDrawingBuffer:false.

Focus modes (--focus-mode):
  hittest (default) : overlay hide → locator("canvas#kvm").click(force=False)
                       → canvas.focus() — uses real hit-testing so
                         viewer.min.js receives the click as a trusted
                         user-initiated event.
  force             : overlay hide → canvas.focus() → click(force=True)
                       (legacy; may not trigger viewer.min.js listeners).

Key modes (--key-mode):
  playwright (default) : page.keyboard.press(key) after focus_kvm()
  dispatch-event       : document.dispatchEvent(KeyboardEvent('keydown'/
                          'keypress'/'keyup', {key, code, bubbles:true}))
                          — fallback when viewer.min.js attaches its
                          listeners at the document level.

Commands:
  screenshot <output.png>             Capture KVM screenshot
  sendkeys <key1> [key2] ...          Press keys sequentially
  type <text>                         Type a literal string
  hold <key> <duration_ms>            Hold a key down for duration_ms
  combo <mod1>+<mod2>+...+<key>       Send a chord (e.g. Control+Alt+Delete)
  wait <seconds>                      Wait
  shell <step1>;<step2>;...           Run several steps in one viewer session
                                       (e.g. "screenshot:before.png; sendkeys:F2; wait:2; screenshot:after.png")

Exit codes:
  0 = success
  1 = connection/auth failure
  2 = canvas / KVM timeout
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
    print("ERROR: playwright not installed", file=sys.stderr)
    sys.exit(3)

import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OEM_SHOT_SH = os.path.join(SCRIPT_DIR, "irmc-oem-screenshot.sh")


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def login_and_get_sid(page, bmc_ip, timeout_sec):
    log(f"Logging in to iRMC at {bmc_ip}")
    page.goto(f"https://{bmc_ip}/", wait_until="networkidle",
              timeout=timeout_sec * 1000)
    page.click('input[name="P99"]', timeout=timeout_sec * 1000)
    page.wait_for_load_state("networkidle", timeout=timeout_sec * 1000)
    m = re.search(r'sid=([^&#]+)', page.url)
    if not m:
        raise RuntimeError(f"Login did not yield SID in URL: {page.url}")
    sid = m.group(1)
    log(f"Login successful (SID: {sid[:8]}...)")
    return sid


def open_viewer(context, bmc_ip, sid, timeout_sec):
    viewer_url = f"https://{bmc_ip}/viewer.html?ms=0&lang=0&sid={sid}"
    log(f"Opening viewer: {viewer_url}")
    viewer_page = context.new_page()
    viewer_page.goto(viewer_url, wait_until="load",
                     timeout=timeout_sec * 1000)
    viewer_page.wait_for_selector("canvas#kvm", timeout=timeout_sec * 1000)

    deadline = time.time() + timeout_sec
    last_w = last_h = 0
    while time.time() < deadline:
        info = viewer_page.evaluate(
            """() => {
                const c = document.getElementById('kvm');
                if (!c) return {w: 0, h: 0, alive: false};
                return {w: c.width, h: c.height,
                        alive: c.classList.contains('alive')};
            }"""
        )
        if info["alive"] and info["w"] > 100:
            last_w = info["w"]
            last_h = info["h"]
            break
        time.sleep(0.5)
    if last_w == 0:
        raise TimeoutError("KVM canvas did not become 'alive' within timeout")
    log(f"Canvas: {last_w}x{last_h} alive=True")
    # Give the WebSocket a beat to flush initial frames
    time.sleep(1.0)
    return viewer_page


def _hide_processing_overlay(viewer_page):
    """Hide the loading overlay that intercepts pointer events.

    iRMC Web UI overlays `<div id="processing_maindiv">` and `.processing_bg`
    popups during viewer init; they keep accepting pointer events even after
    the canvas comes alive, so we must hide them before clicking the canvas.
    """
    viewer_page.evaluate("""() => {
        const overlay = document.getElementById('processing_maindiv');
        if (overlay) overlay.style.display = 'none';
        const popups = document.querySelectorAll('.processing_bg, .processing_bg_inner');
        popups.forEach(el => el.style.display = 'none');
        const c = document.getElementById('kvm');
        if (c) c.setAttribute('tabindex', '0');
    }""")


def _focus_force(viewer_page):
    """Legacy focus path: canvas.focus() then click(force=True)."""
    _hide_processing_overlay(viewer_page)
    viewer_page.evaluate("""() => {
        const c = document.getElementById('kvm');
        if (c) c.focus();
    }""")
    try:
        viewer_page.click("canvas#kvm", timeout=2000, force=True)
    except Exception as e:
        log(f"  (canvas click warning: {e})")
    time.sleep(0.2)


def _focus_hittest(viewer_page):
    """New focus path: real hit-tested click via locator (force=False).

    viewer.min.js may require a trusted user-initiated event to register its
    KVM session as active. force=False makes Playwright perform actual
    hit-testing — if the overlay is not fully hidden, the click would fail
    and surface a warning we can act on, rather than silently bypassing.
    """
    _hide_processing_overlay(viewer_page)
    try:
        viewer_page.locator("canvas#kvm").click(force=False, timeout=5000)
    except Exception as e:
        log(f"  (hittest click failed, falling back to force=True: {e})")
        try:
            viewer_page.click("canvas#kvm", timeout=2000, force=True)
        except Exception as e2:
            log(f"  (force-click warning: {e2})")
    viewer_page.evaluate("""() => {
        const c = document.getElementById('kvm');
        if (c) c.focus();
    }""")
    time.sleep(0.3)


FOCUS_MODE = "hittest"  # set by main(); "hittest" (new) or "force" (legacy)
CAPTURE_MODE = "locator"  # set by main(); "locator" (new) or "canvas" (legacy)
KEY_MODE = "playwright"  # set by main(); "playwright" (new) or "dispatch-event" (legacy DOM)


def focus_kvm(viewer_page):
    """Dispatch to the configured focus path."""
    if FOCUS_MODE == "force":
        _focus_force(viewer_page)
    else:
        _focus_hittest(viewer_page)


def _capture_locator(viewer_page, output):
    """New capture path: locator.screenshot() returns composed frame."""
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    viewer_page.locator("canvas#kvm").screenshot(path=output)
    size = os.path.getsize(output)
    log(f"Saved {output} ({size} bytes, locator)")
    return size


def _capture_canvas_dataurl(viewer_page, output):
    """Legacy capture path: canvas.toDataURL() — returns black for WebGL canvases
    with preserveDrawingBuffer:false."""
    data_url = viewer_page.evaluate("""() => {
        const c = document.getElementById('kvm');
        return c ? c.toDataURL('image/png') : null;
    }""")
    if not data_url or not data_url.startswith("data:image/png;base64,"):
        raise RuntimeError("Failed to capture canvas as data URL")
    png = base64.b64decode(data_url.split(",", 1)[1])
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    with open(output, "wb") as f:
        f.write(png)
    log(f"Saved {output} ({len(png)} bytes, canvas)")
    return len(png)


def capture(viewer_page, output):
    """Dispatch to the configured capture path."""
    if CAPTURE_MODE == "canvas":
        return _capture_canvas_dataurl(viewer_page, output)
    return _capture_locator(viewer_page, output)


def canvas_info(viewer_page):
    return viewer_page.evaluate(
        """() => {
            const c = document.getElementById('kvm');
            if (!c) return {w: 0, h: 0, alive: false, sum: 0};
            const ctx = c.getContext('2d');
            const w = Math.min(c.width, 100);
            const h = Math.min(c.height, 100);
            let sum = 0;
            try {
                const d = ctx.getImageData(0, 0, w, h).data;
                for (let i = 0; i < d.length; i += 4) {
                    sum += d[i] + d[i+1] + d[i+2];
                }
            } catch (e) { sum = -1; }
            return {w: c.width, h: c.height,
                    alive: c.classList.contains('alive'),
                    sum: sum};
        }"""
    )


def force_refresh(viewer_page, output=None):
    """Send Control x3 + canvas resize event to coax a full frame."""
    focus_kvm(viewer_page)
    for _ in range(3):
        viewer_page.keyboard.press("Control")
        time.sleep(0.05)
    viewer_page.evaluate("""() => {
        const c = document.getElementById('kvm');
        if (c) c.dispatchEvent(new Event('resize'));
    }""")
    time.sleep(0.5)
    if output:
        capture(viewer_page, output)


def capture_with_retry(viewer_page, output, max_retries=3,
                        min_size_bytes=8000, min_pixel_sum=1000):
    """Capture canvas, retry with force-refresh if black/empty."""
    for attempt in range(1, max_retries + 1):
        size = capture(viewer_page, output)
        info = canvas_info(viewer_page)
        if size >= min_size_bytes and info["sum"] >= min_pixel_sum:
            return True
        log(f"  black/empty frame (size={size}, pixel_sum={info['sum']}), "
            f"attempt {attempt}/{max_retries} — force-refresh")
        force_refresh(viewer_page)
    log(f"  WARNING: capture remained black/empty after {max_retries} retries")
    return False


def assert_canvas_size(viewer_page, min_w, min_h, timeout_sec=30):
    """Wait until canvas reaches at least (min_w, min_h)."""
    deadline = time.time() + timeout_sec
    last = {"w": 0, "h": 0, "alive": False}
    while time.time() < deadline:
        info = canvas_info(viewer_page)
        last = info
        if info["alive"] and info["w"] >= min_w and info["h"] >= min_h:
            log(f"  canvas {info['w']}x{info['h']} >= {min_w}x{min_h} OK")
            return True
        time.sleep(1.0)
        if (time.time() - deadline + timeout_sec) % 5 < 1.0:
            force_refresh(viewer_page)
    log(f"  TIMEOUT: canvas stuck at {last['w']}x{last['h']} "
        f"(needed {min_w}x{min_h})")
    return False


def _dispatch_key_event(viewer_page, key, event_type):
    """Synthesize a single KeyboardEvent via document.dispatchEvent.

    Used when viewer.min.js attaches its handlers at the document level —
    in that case `page.keyboard.press` (which targets activeElement) may
    not route to the listener, while a document-level dispatchEvent does.
    """
    viewer_page.evaluate(
        """([key, etype]) => {
            const ev = new KeyboardEvent(etype, {
                key: key,
                code: key,
                bubbles: true,
                cancelable: true,
            });
            document.dispatchEvent(ev);
        }""",
        [key, event_type],
    )


def _press_key(viewer_page, key, wait_ms):
    """Press one key using the configured key-mode."""
    if KEY_MODE == "dispatch-event":
        _dispatch_key_event(viewer_page, key, "keydown")
        time.sleep(0.02)
        _dispatch_key_event(viewer_page, key, "keypress")
        time.sleep(0.02)
        _dispatch_key_event(viewer_page, key, "keyup")
    else:
        viewer_page.keyboard.press(key)
    time.sleep(wait_ms / 1000.0)


def send_keys(viewer_page, keys, wait_ms=100):
    focus_kvm(viewer_page)
    for i, key in enumerate(keys, 1):
        log(f"[{i}/{len(keys)}] press {key!r}")
        _press_key(viewer_page, key, wait_ms)


def type_text(viewer_page, text, wait_ms=30):
    focus_kvm(viewer_page)
    if KEY_MODE == "dispatch-event":
        for ch in text:
            _dispatch_key_event(viewer_page, ch, "keydown")
            _dispatch_key_event(viewer_page, ch, "keypress")
            _dispatch_key_event(viewer_page, ch, "keyup")
            time.sleep(wait_ms / 1000.0)
    else:
        for ch in text:
            viewer_page.keyboard.type(ch)
            time.sleep(wait_ms / 1000.0)


def hold_key(viewer_page, key, duration_ms):
    focus_kvm(viewer_page)
    if KEY_MODE == "dispatch-event":
        _dispatch_key_event(viewer_page, key, "keydown")
        time.sleep(duration_ms / 1000.0)
        _dispatch_key_event(viewer_page, key, "keyup")
    else:
        viewer_page.keyboard.down(key)
        time.sleep(duration_ms / 1000.0)
        viewer_page.keyboard.up(key)


def combo(viewer_page, chord, wait_ms=100):
    """Send a chord like 'Control+Alt+Delete'.

    For dispatch-event mode we synthesize modifier keydowns first, fire the
    main key, then keyup the modifiers — the listener sees modifiers as held
    via ev.ctrlKey/altKey/etc. (note: dispatch-event mode constructs a fresh
    KeyboardEvent without modifier state; for true chord behavior the
    playwright mode is recommended).
    """
    parts = chord.split("+")
    focus_kvm(viewer_page)
    if KEY_MODE == "dispatch-event":
        for p in parts[:-1]:
            _dispatch_key_event(viewer_page, p, "keydown")
            time.sleep(0.05)
        _dispatch_key_event(viewer_page, parts[-1], "keydown")
        time.sleep(0.02)
        _dispatch_key_event(viewer_page, parts[-1], "keypress")
        time.sleep(0.02)
        _dispatch_key_event(viewer_page, parts[-1], "keyup")
        time.sleep(wait_ms / 1000.0)
        for p in reversed(parts[:-1]):
            _dispatch_key_event(viewer_page, p, "keyup")
            time.sleep(0.05)
    else:
        for p in parts[:-1]:
            viewer_page.keyboard.down(p)
            time.sleep(0.05)
        viewer_page.keyboard.press(parts[-1])
        time.sleep(wait_ms / 1000.0)
        for p in reversed(parts[:-1]):
            viewer_page.keyboard.up(p)
            time.sleep(0.05)


def reopen_viewer(context, bmc_ip, sid, timeout_sec, page=None):
    """Re-open the viewer. If SID is stale, the caller should re-login first."""
    try:
        if page is not None and not page.is_closed():
            page.close()
    except Exception:
        pass
    return open_viewer(context, bmc_ip, sid, timeout_sec)


def run_shell(viewer_page, script, default_wait_ms=300,
              bmc_ip=None, bmc_user=None, bmc_pass=None,
              context=None, sid=None, timeout_sec=30,
              screenshot_each_prefix=None):
    """Run a semicolon-separated list of steps.

    Step syntax: <op>:<arg1>[,<arg2>...]
      screenshot:path.png       canvas.toDataURL PNG (subject to frame refresh)
      capture:path.png          alias of screenshot with black-frame retry
      oem-shot:path.jpg         Fujitsu OEM Make+Preview JPEG (BMC-side capture)
      sendkeys:Enter,F2,Escape  press keys (records screenshot-each if enabled)
      type:hello world
      combo:Control+Alt+Delete
      hold:Enter,500            (key, duration_ms)
      wait:2.5                  (seconds)
      release-kvm               close viewer page (so OEM Make can run)
      reopen-kvm                re-open viewer page (after release-kvm)
      force-refresh[:path.png]  Control x3 + canvas resize, optional capture
      assert-canvas:WxH[,sec]   wait until canvas >= WxH (default 30s timeout)
    """
    state = {"viewer": viewer_page, "shot_counter": 0}

    def shot_each(label):
        if not screenshot_each_prefix:
            return
        state["shot_counter"] += 1
        path = f"{screenshot_each_prefix}_{state['shot_counter']:03d}_{label}.png"
        try:
            capture(state["viewer"], path)
        except Exception as e:
            log(f"  shot-each FAILED: {e}")

    for raw in script.split(";"):
        step = raw.strip()
        if not step:
            continue
        if ":" in step:
            op, arg = step.split(":", 1)
        else:
            op, arg = step, ""
        op = op.strip()
        arg = arg.strip()
        log(f"step: {op}({arg!r})")
        v = state["viewer"]
        if op == "screenshot":
            capture(v, arg)
        elif op == "capture":
            capture_with_retry(v, arg)
        elif op == "force-refresh":
            force_refresh(v, arg or None)
        elif op == "assert-canvas":
            if "," in arg:
                size_part, sec_part = arg.split(",", 1)
                sec = float(sec_part.strip())
            else:
                size_part, sec = arg, 30.0
            w_str, h_str = size_part.lower().split("x", 1)
            w, h = int(w_str.strip()), int(h_str.strip())
            ok = assert_canvas_size(v, w, h, timeout_sec=sec)
            if not ok:
                log(f"  assert-canvas FAILED at {w}x{h}")
        elif op == "release-kvm":
            try:
                if v and not v.is_closed():
                    v.close()
                state["viewer"] = None
                log("  viewer released")
            except Exception as e:
                log(f"  release WARN: {e}")
        elif op == "reopen-kvm":
            if not (context and sid):
                log("  ERROR: reopen-kvm requires --bmc-ip + login state")
                continue
            try:
                state["viewer"] = open_viewer(context, bmc_ip, sid, timeout_sec)
                log("  viewer reopened")
            except Exception as e:
                log(f"  reopen FAILED: {e}")
        elif op == "oem-shot":
            if not (bmc_ip and bmc_user and bmc_pass):
                log("  ERROR: oem-shot requires --bmc-ip/--bmc-user/--bmc-pass")
                continue
            ok = False
            for retry in range(1, 4):
                res = subprocess.run(
                    [OEM_SHOT_SH, bmc_ip, bmc_user, bmc_pass, arg, "5", "3"],
                    capture_output=True, text=True,
                )
                if res.returncode == 0:
                    log(f"  oem-shot ok (try {retry}): {res.stdout.strip()}")
                    ok = True
                    break
                log(f"  oem-shot FAILED (try {retry}) rc={res.returncode}: "
                    f"{res.stderr.strip()[:200]}")
                time.sleep(2)
            if not ok:
                log(f"  oem-shot gave up after 3 tries: {arg}")
        elif op == "sendkeys":
            keys = [k.strip() for k in arg.split(",") if k.strip()]
            for k in keys:
                send_keys(v, [k], wait_ms=default_wait_ms)
                shot_each(k.replace("+", "_"))
        elif op == "type":
            type_text(v, arg)
            shot_each("type")
        elif op == "combo":
            combo(v, arg)
            shot_each(arg.replace("+", "_"))
        elif op == "hold":
            key, dur = arg.split(",")
            hold_key(v, key.strip(), int(dur.strip()))
            shot_each(key.strip())
        elif op == "wait":
            time.sleep(float(arg))
        else:
            log(f"  WARNING: unknown step op {op!r}")


def main():
    parser = argparse.ArgumentParser(description="iRMC S4 HTML5 KVM control")
    parser.add_argument("--bmc-ip", required=True)
    parser.add_argument("--bmc-user", required=True)
    parser.add_argument("--bmc-pass", required=True)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--wait-ms", type=int, default=100,
                        help="Delay between key presses (default 100)")
    parser.add_argument("--no-headless", dest="headless",
                        action="store_false", default=True)
    parser.add_argument("--capture-mode",
                        choices=["locator", "canvas"], default="locator",
                        help="locator (default, composed frame via element "
                             "screenshot) or canvas (legacy toDataURL, returns "
                             "black for WebGL preserveDrawingBuffer:false)")
    parser.add_argument("--focus-mode",
                        choices=["hittest", "force"], default="hittest",
                        help="hittest (default, real click via locator.click "
                             "force=False) or force (legacy click force=True)")
    parser.add_argument("--key-mode",
                        choices=["playwright", "dispatch-event"],
                        default="playwright",
                        help="playwright (default, page.keyboard.press) or "
                             "dispatch-event (document.dispatchEvent of "
                             "KeyboardEvent — for viewer listeners attached "
                             "at document level)")

    sub = parser.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("screenshot")
    sp.add_argument("output")

    sp = sub.add_parser("sendkeys")
    sp.add_argument("keys", nargs="+")
    sp.add_argument("--screenshot")

    sp = sub.add_parser("type")
    sp.add_argument("text")
    sp.add_argument("--screenshot")

    sp = sub.add_parser("hold")
    sp.add_argument("key")
    sp.add_argument("duration_ms", type=int)
    sp.add_argument("--screenshot")

    sp = sub.add_parser("combo")
    sp.add_argument("chord", help="e.g. Control+Alt+Delete")
    sp.add_argument("--screenshot")

    sp = sub.add_parser("shell")
    sp.add_argument("script", help="step1;step2;... (see source for syntax)")
    sp.add_argument("--screenshot-each",
                    help="If set, capture PNG after each key step. "
                         "Files: <prefix>_NNN_<label>.png")

    args = parser.parse_args()

    global FOCUS_MODE, CAPTURE_MODE, KEY_MODE
    FOCUS_MODE = args.focus_mode
    CAPTURE_MODE = args.capture_mode
    KEY_MODE = args.key_mode
    log(f"modes: capture={CAPTURE_MODE} focus={FOCUS_MODE} key={KEY_MODE}")

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=args.headless,
            args=["--ignore-certificate-errors", "--no-sandbox", "--disable-gpu"],
        )
        try:
            context = browser.new_context(
                ignore_https_errors=True,
                http_credentials={"username": args.bmc_user,
                                  "password": args.bmc_pass},
                viewport={"width": 1280, "height": 1024},
            )
            page = context.new_page()
            sid = login_and_get_sid(page, args.bmc_ip, args.timeout)
            viewer_page = open_viewer(context, args.bmc_ip, sid, args.timeout)

            if args.command == "screenshot":
                capture(viewer_page, args.output)
            elif args.command == "sendkeys":
                send_keys(viewer_page, args.keys, wait_ms=args.wait_ms)
                if args.screenshot:
                    time.sleep(0.5)
                    capture(viewer_page, args.screenshot)
            elif args.command == "type":
                type_text(viewer_page, args.text)
                if args.screenshot:
                    time.sleep(0.5)
                    capture(viewer_page, args.screenshot)
            elif args.command == "hold":
                hold_key(viewer_page, args.key, args.duration_ms)
                if args.screenshot:
                    time.sleep(0.5)
                    capture(viewer_page, args.screenshot)
            elif args.command == "combo":
                combo(viewer_page, args.chord)
                if args.screenshot:
                    time.sleep(0.5)
                    capture(viewer_page, args.screenshot)
            elif args.command == "shell":
                run_shell(viewer_page, args.script,
                          default_wait_ms=args.wait_ms,
                          bmc_ip=args.bmc_ip,
                          bmc_user=args.bmc_user,
                          bmc_pass=args.bmc_pass,
                          context=context,
                          sid=sid,
                          timeout_sec=args.timeout,
                          screenshot_each_prefix=getattr(
                              args, "screenshot_each", None))
        finally:
            browser.close()


if __name__ == "__main__":
    try:
        main()
    except TimeoutError as e:
        log(f"TIMEOUT: {e}")
        sys.exit(2)
    except Exception as e:
        log(f"ERROR: {e}")
        sys.exit(1)
