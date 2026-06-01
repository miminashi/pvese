#!/usr/bin/env python3
"""Persistent iRMC KVM session driver (FW 9.69F).

Opens ONE viewer session, gains master control, and HOLDS it for the whole
run — solving the lingering-master partial-access problem (a closed session
keeps the KVM master slot for minutes; reopening lands you as read-only
slave). Drives the session via command files:

  - drop command files into  <srv-dir>/in/<NNN>.cmd  (one command per line)
  - server executes them in filename order, screenshots to <srv-dir>/shots/
  - per .cmd file it writes  <srv-dir>/out/<NNN>.log  then renames .cmd -> .done

Commands (one per line):
  press <key> [ms]              press a key, wait ms (default 700)
  dpress <key> [ms]             dispatchEvent key (document-level), wait ms
  keyrepeat <key> <n> [ms]      press key n times
  dkeyrepeat <key> <n> [ms]     dispatch key n times
  hold <key> [ms]               key down, wait ms, key up
  focus                         re-establish keyboard focus on the canvas
  mouse <cx> <cy>               click at canvas-relative coords (1024x768 space)
  shot <name>                   screenshot <srv-dir>/shots/<name>, log size+cursor_y
  navy <y> [caret|highlight] [maxpress] [settle_ms]   nav_cursor_to_y
  sleep <s>
  note <text>
  quit                          close viewer and exit

Usage:
  .venv/bin/python scripts/irmc-kvm/server.py \\
      --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \\
      --srv-dir tmp/<session-id>/srv [--idle-timeout 7200]

Promoted from tmp/503d9361/kvm_server.py (2026-06-01 503d9361, issue #73).
Parameterized: BMC credentials via --bmc-* args (threaded through
gain_control -> open_viewer, no longer hardcoded), session dir via --srv-dir,
idle timeout via --idle-timeout (default 7200s, matching the validated run).
"""
import argparse
import glob
import os
import sys
import time

# kvmlib.py + _util.py live in the same directory after promotion.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kvmlib import (open_viewer, shot, press, log, detect_cursor_row,  # noqa: E402
                    detect_active_cursor_row, nav_cursor_to_y,
                    _dismiss_partial_access_dialog)


def gain_control(p, bmc, usr, psw, shots_dir, max_reconnect=18):
    """Open viewer + gain master control, reconnecting if we land as slave.

    Exception-safe: a reopened viewer can transiently have an invisible canvas
    (screenshot raises) — treat that as 'no control yet' and reconnect.
    """
    for attempt in range(1, max_reconnect + 1):
        browser = ctx = vp = None
        try:
            browser, ctx, vp = open_viewer(p, bmc=bmc, usr=usr, psw=psw,
                                           warmup_s=12, wake=False)
            ok = False
            for sub in range(3):
                try:
                    _dismiss_partial_access_dialog(vp)
                    before = shot(vp, os.path.join(shots_dir, "ctl_before.png"))
                    # Control test via TAB switch (ArrowRight), NOT F1 — F1
                    # opens the General Help modal which does not reliably
                    # close with Esc and then blocks all navigation keys.
                    press(vp, "ArrowRight", 1500)
                    after = shot(vp, os.path.join(shots_dir, "ctl_right.png"))
                    press(vp, "ArrowLeft", 1500)   # switch back
                    log(f"gain_control[{attempt}/{max_reconnect}.{sub}]: "
                        f"before={before} right={after} delta={after-before:+d}")
                    if abs(after - before) > 300:
                        log("  -> MASTER control confirmed (tab switch)")
                        ok = True
                        break
                except Exception as e:
                    log(f"  control-test err: {type(e).__name__}: {str(e)[:90]}")
                time.sleep(12)
            if ok:
                return browser, ctx, vp
        except Exception as e:
            log(f"gain_control[{attempt}] open err: {type(e).__name__}: {str(e)[:90]}")
        log("  -> no control. Close + wait 40s, reconnect.")
        try:
            if browser:
                browser.close()
        except Exception:
            pass
        time.sleep(40)
    raise RuntimeError("could not gain master control")


def focus_canvas(vp):
    """Re-establish keyboard focus on the KVM canvas (lost on dialog open?)."""
    try:
        vp.locator("canvas#kvm").click(force=True, timeout=5000)
    except Exception:
        pass
    try:
        vp.evaluate("""() => { const c=document.getElementById('kvm');
            if (c){ c.setAttribute('tabindex','0'); c.focus(); } }""")
    except Exception:
        pass


def dispatch_key(vp, key):
    """Send a key via document-level dispatchEvent (keydown/keypress/keyup)."""
    vp.evaluate("""(key) => {
        for (const etype of ['keydown','keypress','keyup']) {
            const ev = new KeyboardEvent(etype, {key:key, code:key,
                bubbles:true, cancelable:true});
            document.dispatchEvent(ev);
        }
    }""", key)


def do_shot(vp, shots_dir, name, fout):
    pth = os.path.join(shots_dir, name)
    sz = shot(vp, pth)
    yc = detect_cursor_row(pth)
    yh = detect_active_cursor_row(pth)
    line = f"shot {name}: size={sz} caret_y={yc} hl_y={yh}"
    log("  " + line)
    fout.write(line + "\n")


def exec_cmd(vp, shots_dir, line, fout):
    parts = line.split()
    if not parts:
        return True
    c = parts[0]
    if c == "press":
        key = parts[1]
        ms = int(parts[2]) if len(parts) > 2 else 700
        press(vp, key, ms)
    elif c == "dpress":
        key = parts[1]
        ms = int(parts[2]) if len(parts) > 2 else 700
        dispatch_key(vp, key)
        time.sleep(ms / 1000.0)
    elif c == "focus":
        focus_canvas(vp)
    elif c == "mouse":
        cx = float(parts[1]); cy = float(parts[2])
        box = vp.locator("canvas#kvm").bounding_box()
        if box:
            px = box["x"] + cx * (box["width"] / 1024.0)
            py = box["y"] + cy * (box["height"] / 768.0)
            vp.mouse.click(px, py)
            fout.write(f"mouse canvas({cx},{cy}) -> page({px:.0f},{py:.0f})\n")
        else:
            fout.write("mouse: canvas bbox unavailable\n")
        time.sleep(1.2)
    elif c == "hold":
        key = parts[1]
        dur = int(parts[2]) if len(parts) > 2 else 400
        vp.keyboard.down(key)
        time.sleep(dur / 1000.0)
        vp.keyboard.up(key)
        time.sleep(0.7)
    elif c == "keyrepeat":
        key = parts[1]
        n = int(parts[2])
        ms = int(parts[3]) if len(parts) > 3 else 700
        for _ in range(n):
            press(vp, key, ms)
    elif c == "dkeyrepeat":
        key = parts[1]
        n = int(parts[2])
        ms = int(parts[3]) if len(parts) > 3 else 700
        for _ in range(n):
            dispatch_key(vp, key)
            time.sleep(ms / 1000.0)
    elif c == "shot":
        do_shot(vp, shots_dir, parts[1], fout)
    elif c == "navy":
        ty = int(parts[1])
        det = parts[2] if len(parts) > 2 else "caret"
        mp = int(parts[3]) if len(parts) > 3 else 25
        settle = int(parts[4]) if len(parts) > 4 else 1200
        n = nav_cursor_to_y(vp, shots_dir, ty, max_press=mp, tol=8,
                            label="navy", detector=det, settle_ms=settle)
        fout.write(f"navy {ty} {det}: presses={n}\n")
    elif c == "sleep":
        time.sleep(float(parts[1]))
    elif c == "note":
        fout.write("note: " + line[5:] + "\n")
    elif c == "quit":
        return False
    else:
        fout.write(f"UNKNOWN cmd: {line}\n")
    return True


def main():
    ap = argparse.ArgumentParser(description="Persistent iRMC KVM session driver (FW 9.69F)")
    ap.add_argument("--bmc-ip", required=True)
    ap.add_argument("--bmc-user", required=True)
    ap.add_argument("--bmc-pass", required=True)
    ap.add_argument("--srv-dir", required=True,
                    help="session command dir (e.g. tmp/<sid>/srv); in/out/shots created under it")
    ap.add_argument("--idle-timeout", type=int, default=7200,
                    help="exit after this many seconds with no command file (default 7200)")
    args = ap.parse_args()

    root = os.path.abspath(args.srv_dir)
    in_dir = os.path.join(root, "in")
    out_dir = os.path.join(root, "out")
    shots_dir = os.path.join(root, "shots")
    for d in (in_dir, out_dir, shots_dir):
        os.makedirs(d, exist_ok=True)

    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser, ctx, vp = gain_control(p, args.bmc_ip, args.bmc_user,
                                        args.bmc_pass, shots_dir)
        log("=== KVM server READY (master control held) ===")
        with open(os.path.join(out_dir, "ready.log"), "w") as rf:
            do_shot(vp, shots_dir, "server_ready.png", rf)
        last_idle = time.time()
        try:
            while True:
                cmds = sorted(glob.glob(os.path.join(in_dir, "*.cmd")))
                if not cmds:
                    if time.time() - last_idle > args.idle_timeout:
                        log("idle timeout"); break
                    time.sleep(1); continue
                last_idle = time.time()
                cf = cmds[0]
                base = os.path.basename(cf)[:-4]
                log(f"--- executing {base} ---")
                with open(cf) as f:
                    lines = [ln.strip() for ln in f if ln.strip()]
                cont = True
                with open(os.path.join(out_dir, base + ".log"), "w") as fout:
                    for ln in lines:
                        log(f"  cmd: {ln}")
                        fout.write(f"> {ln}\n")
                        try:
                            cont = exec_cmd(vp, shots_dir, ln, fout)
                        except Exception as e:
                            fout.write(f"  ERROR {type(e).__name__}: {str(e)[:160]}\n")
                            log(f"  ERROR {type(e).__name__}: {str(e)[:160]}")
                        if not cont:
                            break
                os.rename(cf, os.path.join(in_dir, base + ".done"))
                if not cont:
                    log("quit received"); break
        finally:
            browser.close()
    log("=== KVM server stopped ===")


if __name__ == "__main__":
    main()
