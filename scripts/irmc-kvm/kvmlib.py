#!/usr/bin/env python3
"""FW 9.69F-compatible KVM viewer opener.

Reuses all navigation/detection helpers from _util.py (same directory) but
replaces open_viewer() with a cookie-session login (FW 9.69F puts the SID in a
cookie named 'sid', NOT in the URL — the legacy open_viewer's `re.search(sid=...)`
on page.url therefore always failed). The viewer.html page authenticates via
the session cookie, so no sid query param is needed.

Promoted from tmp/503d9361/kvmlib.py (2026-06-01 503d9361, issue #73). The BMC
/ USR / PSW module constants below are defaults only — callers (e.g. server.py)
pass real credentials to open_viewer().
"""
import os
import sys
import time

# _util.py lives in the same directory after promotion to scripts/irmc-kvm/.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _util import (  # noqa: E402,F401
    log, shot, press, detect_cursor_row, detect_active_cursor_row,
    nav_cursor_to_y, nav_arrowdown_to, nav_arrowup_to, identify_state,
    assert_state, clear_configuration, emergency_esc_out,
    safe_navigate_to_advanced_tab, navigate_to_avago_main,
    _dismiss_partial_access_dialog, CURSOR_Y_ADVANCED_TAB,
    CURSOR_Y_AVAGO_MAIN_MENU, CURSOR_Y_CFG_MGMT, CURSOR_Y_CLEAR_CONFIG_DIALOG,
    CURSOR_Y_CREATE_VD_FORM, WAIT_MS_FAST, WAIT_MS_DIALOG, WAIT_MS_POPUP,
    WAIT_MS_LONG,
)

BMC = "10.254.254.9"
USR = "claude"
PSW = "Claude123"


def ensure_control(vp, sdir, max_tries=10, wait_s=20):
    """Verify this KVM session has MASTER (write) control, not slave/view-only.

    A second KVM session connecting while a prior session is still master gets
    read-only access — keystrokes are silently dropped. We test control by
    pressing F1 (opens BIOS Help overlay on ANY screen) and checking the
    screenshot size changes; if it does, we have control (then Esc to close
    Help). If not, we keep dismissing the partial-access dialog and waiting
    for the lingering master session to expire.

    Returns True once control confirmed, else False after max_tries.
    """
    import os
    for i in range(1, max_tries + 1):
        _dismiss_partial_access_dialog(vp)
        before = shot(vp, os.path.join(sdir, f"ctl_{i:02d}_before.png"))
        press(vp, "F1", 1500)
        after = shot(vp, os.path.join(sdir, f"ctl_{i:02d}_f1.png"))
        log(f"  ensure_control[{i}/{max_tries}]: before={before} f1={after} delta={after-before:+d}")
        if abs(after - before) > 300:
            # Help opened -> we have control. Close it.
            press(vp, "Escape", 1500)
            log("  -> control CONFIRMED (F1 Help opened)")
            return True
        log(f"  -> no control yet, waiting {wait_s}s for master session to expire")
        time.sleep(wait_s)
    log("  ensure_control: FAILED to gain control")
    return False


def open_viewer(p, bmc=BMC, usr=USR, psw=PSW, warmup_s=15, wake=True,
                tolerate_partial=True, login_retries=3, login_retry_wait_s=30):
    """Open iRMC KVM viewer on FW 9.69F (cookie-session). Returns (browser,ctx,vp)."""
    browser = p.chromium.launch(
        headless=True,
        args=["--ignore-certificate-errors", "--no-sandbox", "--disable-gpu"],
    )
    ctx = browser.new_context(
        ignore_https_errors=True,
        http_credentials={"username": usr, "password": psw},
        viewport={"width": 1280, "height": 1024},
    )
    pg = ctx.new_page()
    logged_in = False
    for attempt in range(1, login_retries + 1):
        log(f"Login to {bmc} (attempt {attempt}/{login_retries})")
        try:
            pg.goto(f"https://{bmc}/login", wait_until="domcontentloaded",
                    timeout=45000)
            if pg.locator('input[name="P99"]').count():
                pg.click('input[name="P99"]', timeout=30000)
            time.sleep(3)
            # FW 9.69F: success == a 'sid' cookie is present
            sid_cookie = [c for c in ctx.cookies() if c["name"] == "sid"]
            if sid_cookie:
                log(f"Login OK (sid cookie {sid_cookie[0]['value'][:8]}...)")
                logged_in = True
                break
            log(f"  no sid cookie yet (url={pg.url})")
        except Exception as e:
            log(f"  login failed: {type(e).__name__}: {str(e)[:120]}")
        if attempt < login_retries:
            log(f"  retrying in {login_retry_wait_s}s")
            time.sleep(login_retry_wait_s)
    if not logged_in:
        raise RuntimeError(f"Failed to login to {bmc} after {login_retries} attempts")

    vp = ctx.new_page()
    for attempt in range(1, login_retries + 1):
        try:
            vp.goto(f"https://{bmc}/viewer.html?ms=0&lang=0",
                    wait_until="load", timeout=45000)
            vp.wait_for_selector("canvas#kvm", timeout=45000)
            break
        except Exception as e:
            log(f"  viewer open failed (attempt {attempt}): {type(e).__name__}")
            if attempt < login_retries:
                time.sleep(login_retry_wait_s)
            else:
                raise
    log(f"Warm-up {warmup_s}s")
    time.sleep(warmup_s)
    vp.evaluate("""() => {
        const o = document.getElementById('processing_maindiv');
        if (o) o.style.display = 'none';
        document.querySelectorAll('.processing_bg, .processing_bg_inner')
            .forEach(el => el.style.display = 'none');
        const c = document.getElementById('kvm');
        if (c) c.setAttribute('tabindex', '0');
    }""")
    time.sleep(1)
    # Wait for the KVM canvas to actually become visible + sized (the video
    # stream can take several extra seconds; screenshot fails if not visible).
    for _ in range(20):
        try:
            box = vp.locator("canvas#kvm").bounding_box()
            vis = vp.locator("canvas#kvm").is_visible()
            if vis and box and box["width"] > 100 and box["height"] > 100:
                break
        except Exception:
            pass
        _dismiss_partial_access_dialog(vp)
        vp.evaluate("""() => {
            const o = document.getElementById('processing_maindiv');
            if (o) o.style.display = 'none';
            document.querySelectorAll('.processing_bg, .processing_bg_inner')
                .forEach(el => el.style.display = 'none');
        }""")
        time.sleep(2)
    if tolerate_partial:
        for i in range(3):
            if _dismiss_partial_access_dialog(vp):
                log(f"  dismissed partial-access dialog (attempt {i+1})")
                time.sleep(1)
            else:
                break
    # FW 9.69F: #cursor_canvas overlay intercepts pointer events on #kvm,
    # so a normal hit-test click times out. force=True clicks through it
    # (we only need to establish keyboard focus on the viewer).
    vp.locator("canvas#kvm").click(timeout=10000, force=True)
    time.sleep(2)
    if wake:
        press(vp, "F1", 2000)
        if tolerate_partial:
            _dismiss_partial_access_dialog(vp)
        press(vp, "Escape", 2000)
        if tolerate_partial:
            _dismiss_partial_access_dialog(vp)
    return browser, ctx, vp
