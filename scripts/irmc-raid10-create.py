#!/usr/bin/env python3
# DEPRECATED 2026-05-17 #5 d-eager-island: KVM HII path is a confirmed dead-end
# (Select RAID Level y=128 unreachable via Aptio navigation; see
# report/2026-05-17_101536_tx1320_raid10_dead_end.md). Use
# scripts/tx1320-raid10-orchestrate.sh apply config/training_tx1320.yml
# instead (preseed + storcli ISO-bundle path).
#
# NOTE: This module imports tmp/iter/_util.py which is intentionally not
# tracked (per .gitignore policy for tmp/). The file is retained as a
# historical record of the HII-KVM exploration path only. Phase 18+ may
# remove this file outright.
"""TX1320 M3 iRMC AVAGO HII RAID10 creation CLI wrapper.

Called from scripts/irmc-bios-raid-setup.sh step_S6_S8_python().
Imports tmp/iter/_util.py for cursor navigation primitives.

Pre-conditions:
  - BIOS Setup is open and at AVAGO MegaRAID row (or AVAGO Main).
    Typically achieved by step_S1-S5 in the dispatcher.

Modes:
  create  — execute C1-C13 (form open through Save & Commit)
  verify  — open AVAGO Main → VD Mgmt → screenshot VD0 list
  scout   — open form, screenshot CURSOR_Y map (no changes)
  dry-run — C1-C12 with --skip-confirm (revert at C12)

Exit codes:
  0  success
  1  cursor detection failure (probe / nav)
  2  size fingerprint mismatch
  3  BMC login failure
  4  form open failure
  99 invalid args / internal error
"""
import argparse
import os
import sys

PROJ_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PROJ_ROOT, "tmp", "iter"))

from playwright.sync_api import sync_playwright  # noqa: E402

from _util import (  # noqa: E402
    open_viewer, log,
    navigate_to_avago_main,
    emergency_esc_out,
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bmc-ip", required=True)
    ap.add_argument("--bmc-user", required=True)
    ap.add_argument("--bmc-pass", required=True)
    ap.add_argument("--session-dir", required=True,
                    help="Directory for screenshots / logs")
    ap.add_argument("--mode", choices=["create", "verify", "scout", "dry-run"],
                    default="create")
    ap.add_argument("--warmup-s", type=int, default=15)
    ap.add_argument("--stop-at", default="C13",
                    help="C1..C13 (for create/dry-run modes)")
    ap.add_argument("--skip-confirm", action="store_true",
                    help="At C12, Esc revert instead of commit")
    ap.add_argument("--n-up", type=int, default=1,
                    help="(create) ArrowUp count from y=147 to reach y=128")
    args = ap.parse_args()

    os.makedirs(args.session_dir, exist_ok=True)

    if args.mode == "dry-run":
        args.skip_confirm = True
        args.mode = "create"

    # Import iter_11 lazily (after sys.path is set up)
    from iter_11_raid10_commit import (  # noqa: E402
        step_c1_open_form, step_c2_arrowdown_to_147,
        step_c3_arrowup_to_128, step_c4_select_raid10,
        step_c5_open_drives_popup, step_c6_select_drives_span,
        step_c7_apply_drives, step_c11_save_configuration,
        step_c12_confirm, step_c13_back_to_avago,
    )

    stop_n = int(args.stop_at.upper().lstrip("C"))

    with sync_playwright() as p:
        try:
            browser, ctx, vp = open_viewer(
                p, bmc=args.bmc_ip, usr=args.bmc_user, psw=args.bmc_pass,
                warmup_s=args.warmup_s,
            )
        except RuntimeError as e:
            log(f"BMC login failed: {e}")
            return 3

        try:
            ok = navigate_to_avago_main(vp, args.session_dir)
            if not ok:
                log("navigate_to_avago_main failed"); return 4

            if args.mode == "verify":
                # AVAGO Main -> Virtual Drive Mgmt -> screenshot
                from _util import (
                    press, shot, WAIT_MS_POPUP, WAIT_MS_LONG,
                    nav_cursor_to_y, CURSOR_Y_AVAGO_MAIN_MENU,
                )
                press(vp, "Enter", WAIT_MS_POPUP)
                shot(vp, os.path.join(args.session_dir, "verify_01_main_menu.png"))
                nav_cursor_to_y(
                    vp, args.session_dir,
                    CURSOR_Y_AVAGO_MAIN_MENU["virtual_drive_mgmt"],
                    max_press=8, tol=8, label="verify_02_to_vd_mgmt",
                    detector="caret",
                )
                press(vp, "Enter", WAIT_MS_LONG)
                shot(vp, os.path.join(args.session_dir, "verify_03_vd_list.png"))
                log("verify: VD list screenshot saved")
                return 0

            if args.mode == "scout":
                if not step_c1_open_form(vp): return 4
                if not step_c2_arrowdown_to_147(vp): return 1
                if not step_c3_arrowup_to_128(vp, args.n_up): return 1
                log("scout: form scout done")
                return 0

            # mode == create (or dry-run promoted)
            if stop_n >= 1 and not step_c1_open_form(vp): return 4
            if stop_n >= 2 and not step_c2_arrowdown_to_147(vp): return 1
            if stop_n >= 3 and not step_c3_arrowup_to_128(vp, args.n_up): return 1
            if stop_n >= 4 and not step_c4_select_raid10(vp): return 2
            if stop_n >= 5 and not step_c5_open_drives_popup(vp): return 1
            if stop_n >= 6 and not step_c6_select_drives_span(vp, 0, (0, 1)):
                return 2
            if stop_n >= 7 and not step_c7_apply_drives(vp): return 2
            if stop_n >= 8 and not step_c5_open_drives_popup(vp):  # placeholder
                return 1
            if stop_n >= 9 and not step_c6_select_drives_span(vp, 1, (2, 3)):
                return 2
            if stop_n >= 10 and not step_c7_apply_drives(vp): return 2
            if stop_n >= 11 and not step_c11_save_configuration(vp): return 1
            if stop_n >= 12 and not step_c12_confirm(vp, args.skip_confirm):
                return 1
            if stop_n >= 13 and not step_c13_back_to_avago(vp): return 1
            return 0

        finally:
            try:
                emergency_esc_out(vp, args.session_dir, max_esc=10)
            except Exception as e:
                log(f"esc out: {e}")
            try:
                browser.close()
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
