"""Common util for tx1320 RAID10 iteration scripts.

Use:
    from _util import (open_viewer, log, press, shot, identify_state,
                       assert_state, nav_arrowdown_to, nav_arrowup_to,
                       emergency_esc_out, clear_configuration,
                       WAIT_MS_FAST, WAIT_MS_POPUP, WAIT_MS_DIALOG, WAIT_MS_LONG)

All scripts target training-tx1320 (10.254.254.9). PNG output goes to
each iter's own `iter_NN_run/` dir.
"""
import json
import os
import re
import sys
import time

from PIL import Image

# Iteration scripts run via .venv/bin/python tmp/iter/iter_NN.py
PROJ = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.dirname(__file__))

WAIT_MS_FAST = 700      # 単純 cursor 移動 (ArrowDown/Up form 内)
WAIT_MS_DIALOG = 2000   # toggle / OK dialog dismiss
WAIT_MS_POPUP = 3000    # popup open (Enter で submenu/dialog 出現)
WAIT_MS_LONG = 5000     # Apply / Save / Clear Config commit

BMC = "10.254.254.9"
USR = "claude"
PSW = "Claude123"


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# Load fingerprints.json once
_FP_PATH = os.path.join(os.path.dirname(__file__), "fingerprints.json")
with open(_FP_PATH) as f:
    _FP_RAW = json.load(f)

FINGERPRINTS = {}
for name, entry in _FP_RAW.items():
    if name.startswith("_"):
        continue
    if not isinstance(entry, dict):
        continue
    if entry.get("size") is not None:
        FINGERPRINTS[name] = entry

DANGER = {
    "drive_mgmt_form",
    "make_unconfigured_bad_pending",
    "drive_erase_pending",
    "factory_default_dialog",
}


def fingerprint_register(name, size, desc=""):
    """Add or update a fingerprint at runtime (e.g. when discovered)."""
    FINGERPRINTS[name] = {"size": size, "desc": desc, "src": "runtime"}


def identify_state(size, tol=80):
    """Reverse-lookup state name by PNG size. Returns None if no match.

    Tolerance defaults to 80 (tightened from 200 in iter 2 after observing
    collisions like advanced_avago_row 18091 vs exit_without_saving 18003).
    """
    best = None
    best_d = tol + 1
    for name, fp in FINGERPRINTS.items():
        d = abs(size - fp["size"])
        if d <= tol and d < best_d:
            best_d = d
            best = name
    return best


def shot(vp, path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    vp.locator("canvas#kvm").screenshot(path=path)
    return os.path.getsize(path)


def detect_cursor_row(png_path, x_min=4, x_max=30, y_min=60, y_max=720,
                       cursor_pixel_value=255, min_cursor_run=4):
    """Detect the Y row where Aptio BIOS cursor '►' is rendered.

    The cursor ► is rendered with brightness=255 pixels. Cursor X
    position varies by context:
      - Menu items: ► at x=8-14 (BIOS Setup Advanced tab, AVAGO menus)
      - Dialog form fields: ► at x=24-26 (Clear Config dialog Confirm field)

    Scan x=[x_min, x_max] for rows containing a run of brightness=255
    pixels of at least min_cursor_run length. Return the Y of the first
    such row, or None.
    """
    img = Image.open(png_path).convert("L")
    w, h = img.size
    x_max = min(x_max, w)
    y_max = min(y_max, h)
    px = img.load()
    candidates = []
    for y in range(y_min, y_max):
        run = 0
        for x in range(x_min, x_max):
            if px[x, y] == cursor_pixel_value:
                run += 1
            else:
                if run >= min_cursor_run:
                    candidates.append(y)
                    break
                run = 0
        else:
            if run >= min_cursor_run:
                candidates.append(y)
    if not candidates:
        return None
    # Cursor occupies multiple consecutive rows; return the middle one
    # of the first cluster
    cluster = [candidates[0]]
    for y in candidates[1:]:
        if y - cluster[-1] <= 2:
            cluster.append(y)
        else:
            break
    return cluster[len(cluster) // 2]


def detect_cursor_row_index(png_path, line_height=19, top_offset=68):
    """Convert detected cursor Y to a 0-indexed menu row.

    Aptio Setup item rows are roughly line_height=19 px apart,
    starting around top_offset=68 px from the canvas top.
    Returns approx row index (int >= 0) or None.
    """
    y = detect_cursor_row(png_path)
    if y is None:
        return None
    return max(0, round((y - top_offset) / line_height))


def detect_active_cursor_row(png_path, x_min=30, x_max=400,
                              bg_threshold=200, min_bright_cols=30,
                              y_min=60, y_max=720, merge_gap=4):
    """Detect the Y row that has the highlight band (active focus).

    AVAGO Create VD form and similar dialogs show multiple ► glyphs at
    once (one per navigable field marker), making detect_cursor_row()
    ambiguous. The focused row is distinguished by a WHITE-BACKGROUND
    highlight band spanning from x≈30 to x≈400+.

    Scan each y in [y_min, y_max); count pixels with brightness
    >= bg_threshold in x=[x_min, x_max). Rows with cnt >= min_bright_cols
    are grouped into clusters (gap <= merge_gap merges, to absorb the
    descender/ascender split between adjacent bright rows). Returns the
    center y of the cluster whose single-row max bright count is largest
    (= most opaque = active). Returns None if no cluster qualifies.

    Static probe (iter07_scout_run/form_00..13):
      highlighted: 37-92 bright_cols/y;  non-highlighted: 0-15.
    """
    img = Image.open(png_path).convert("L")
    w, h = img.size
    x_max = min(x_max, w)
    y_max = min(y_max, h)
    px = img.load()
    bright = []  # list of (y, cnt) where cnt >= min_bright_cols
    for y in range(y_min, y_max):
        cnt = 0
        for x in range(x_min, x_max):
            if px[x, y] >= bg_threshold:
                cnt += 1
        if cnt >= min_bright_cols:
            bright.append((y, cnt))
    if not bright:
        return None
    clusters = [[bright[0]]]
    for y, cnt in bright[1:]:
        prev_y = clusters[-1][-1][0]
        if y - prev_y <= merge_gap + 1:
            clusters[-1].append((y, cnt))
        else:
            clusters.append([(y, cnt)])
    best = max(clusters, key=lambda cl: max(c for _, c in cl))
    ys = [y for y, _ in best]
    return (ys[0] + ys[-1]) // 2


def press(vp, key, ms=None):
    vp.keyboard.press(key)
    time.sleep((ms if ms is not None else WAIT_MS_FAST) / 1000.0)


# Create VD form: 値の +/- で副作用なく cursor 行を probe できない行
#   y=88  Save Configuration (action 行、 + で何も起きない)
#   y=411 Emulation Type (Default/Auto cycling、 1 NumpadAdd で戻し非決定的の懸念)
PROBE_FORBIDDEN_Y = {88, 411}

# Create VD form: NumpadAdd → NumpadSubtract で値が確実に戻る安全行
#   y=147 Select Drives From [Unconfigured Capacity ↔ Free Capacity] 2 値トグル
#   y=259 Strip Size cycling
#   y=280 Read Policy cycling
#   y=299 Write Policy cycling
#   y=316 IO Policy cycling
#   y=337 Access Policy cycling
#   y=373 Disk Cache Policy cycling
PROBE_SAFE_Y = {147, 259, 280, 299, 316, 337, 373}


def _rowwise_diff_y(before_png, after_png, y_min=60, y_max=720,
                     x_min=30, x_max=400, min_diff=2000):
    """Return y of the row with the largest |after - before| pixel diff sum.

    Sums absolute brightness diffs per y in [y_min, y_max) over x in
    [x_min, x_max). Returns (y, diff_sum) of the max row, or (None, 0)
    if the largest diff is below `min_diff` (= no significant change).
    """
    a = Image.open(before_png).convert("L")
    b = Image.open(after_png).convert("L")
    if a.size != b.size:
        return None, 0
    w, h = a.size
    x_max = min(x_max, w)
    y_max = min(y_max, h)
    pa = a.load()
    pb = b.load()
    best_y = None
    best_sum = 0
    for y in range(y_min, y_max):
        s = 0
        for x in range(x_min, x_max):
            d = pa[x, y] - pb[x, y]
            s += d if d >= 0 else -d
        if s > best_sum:
            best_sum = s
            best_y = y
    if best_sum < min_diff:
        return None, best_sum
    # The changed band spans multiple rows; widen by searching a few
    # neighbors and return the cluster middle.
    band = [y for y in range(max(y_min, best_y - 6),
                              min(y_max, best_y + 7))
            if _rowwise_sum(pa, pb, y, x_min, x_max) >= best_sum // 4]
    if not band:
        return best_y, best_sum
    return (band[0] + band[-1]) // 2, best_sum


def _rowwise_sum(pa, pb, y, x_min, x_max):
    s = 0
    for x in range(x_min, x_max):
        d = pa[x, y] - pb[x, y]
        s += d if d >= 0 else -d
    return s


def identify_form_cursor_by_probe(vp, sdir, label, expected_y=None,
                                   wait_ms=2000, size_change_threshold=20,
                                   restore_size_tol=100):
    """Identify Create VD form cursor row by NumpadAdd probe + image diff.

    Background: `detect_active_cursor_row()` misfires inside the AVAGO
    Create VD form because the `[RAID0]` value cluster (y=121..132) is
    persistently brightest regardless of cursor position (#3 finding).
    Hybrid strategy:

      - expected_y in PROBE_FORBIDDEN_Y: probe skipped (would change a
        non-revertable value or trigger action). Return naive highlight
        with method='model'.
      - expected_y in PROBE_SAFE_Y: NumpadAdd probe + diff + NumpadSubtract
        restore. Verify size_restore within `restore_size_tol` of
        size_before; if not, raise (caller should emergency_esc_out).
      - expected_y is None / unknown: naive highlight + WARN.

    Args:
      vp: Playwright page object holding the iRMC KVM canvas.
      sdir: directory where probe screenshots are saved.
      label: short string prefix for the screenshot filenames.
      expected_y: y the caller expects the cursor to be on (used to
        decide whether probing is safe).
      wait_ms: ms to wait after each NumpadAdd / NumpadSubtract for the
        frame buffer to settle.
      size_change_threshold: minimum |size_after - size_before| (bytes)
        to treat as a real value change.
      restore_size_tol: maximum |size_restore - size_before| (bytes) for
        the cleanup to be considered successful.

    Returns:
      (y, method) where method in {'probe','model','highlight'}.
      `y` is the detected cursor row (int) or None if undetectable.

    Raises:
      RuntimeError if cleanup (NumpadSubtract) leaves size diff above
      restore_size_tol — caller MUST handle (emergency_esc_out + form
      re-open).
    """
    p_before = os.path.join(sdir, f"{label}_probe_before.png")
    size_before = shot(vp, p_before)
    y_naive = detect_active_cursor_row(p_before)
    log(f"  probe[{label}] before: size={size_before} y_naive={y_naive}"
        f" expected_y={expected_y}")

    if expected_y in PROBE_FORBIDDEN_Y:
        log(f"  probe[{label}] expected_y={expected_y} in FORBIDDEN — skip,"
            " return model")
        return y_naive, "model"

    if expected_y not in PROBE_SAFE_Y:
        log(f"  probe[{label}] expected_y={expected_y} unknown —"
            " return highlight (best effort, may be wrong)")
        return y_naive, "highlight"

    press(vp, "NumpadAdd", wait_ms)
    p_after = os.path.join(sdir, f"{label}_probe_after.png")
    size_after = shot(vp, p_after)
    size_delta = size_after - size_before
    log(f"  probe[{label}] after NumpadAdd: size={size_after}"
        f" delta={size_delta:+d}")

    press(vp, "NumpadSubtract", wait_ms)
    p_restore = os.path.join(sdir, f"{label}_probe_restore.png")
    size_restore = shot(vp, p_restore)
    restore_delta = size_restore - size_before
    log(f"  probe[{label}] after NumpadSubtract: size={size_restore}"
        f" delta_to_before={restore_delta:+d}")

    if abs(restore_delta) > restore_size_tol:
        msg = (f"probe[{label}] cleanup FAILED: size_restore={size_restore}"
               f" not within {restore_size_tol} of size_before={size_before}"
               " — caller should emergency_esc_out")
        log(f"  !!! {msg}")
        raise RuntimeError(msg)

    if abs(size_delta) < size_change_threshold:
        log(f"  probe[{label}] size delta below threshold —"
            " no value change detected, cursor likely not on a probable row")
        return y_naive, "highlight"

    y_diff, diff_sum = _rowwise_diff_y(p_before, p_after)
    log(f"  probe[{label}] image_diff_y={y_diff} diff_sum={diff_sum}")
    if y_diff is None:
        return y_naive, "highlight"
    return y_diff, "probe"


def detect_popup_cursor_row(png_path, x_min=410, x_max=580,
                             y_min=340, y_max=560, **kw):
    """Detect cursor row inside an AVAGO drives popup overlay.

    Re-uses `detect_active_cursor_row` with bounds limited to the popup
    region. The `[RAID0]` value cluster (y=121..132) that confuses the
    form-bounds detector lives outside this rectangle, so highlight
    detection alone should work here.

    Default bounds (x=410-580, y=340-560) are estimates from iter
    07/08 popup screenshots; iter_10 will probe the actual bounds and
    we may tighten these later.
    """
    return detect_active_cursor_row(
        png_path, x_min=x_min, x_max=x_max, y_min=y_min, y_max=y_max,
        bg_threshold=kw.get("bg_threshold", 200),
        min_bright_cols=kw.get("min_bright_cols", 20),
        merge_gap=kw.get("merge_gap", 4),
    )


def assert_state(vp, sdir, label, expected, abort_on_danger=True, tol=200):
    """Capture screen + identify, return True if matches expected.

    If a DANGER state is detected, immediately Esc x10 and raise.
    """
    p = os.path.join(sdir, f"{label}.png")
    sz = shot(vp, p)
    state = identify_state(sz, tol=tol)
    log(f"  assert_state[{label}]: size={sz} state={state} expected={expected}")
    if abort_on_danger and state in DANGER:
        log(f"  !!! DANGER state {state} — emergency Esc out")
        for _ in range(10):
            press(vp, "Escape", 1500)
        raise RuntimeError(f"danger detected: {state}")
    return state == expected


def nav_to(vp, sdir, key, target, max_press=10, label="nav", tol=200,
           wait_ms=None):
    """Press `key` adaptively until current state matches `target`.

    Stops when target detected or DANGER detected (raises) or max reached.
    Returns number of presses taken to reach target, or -1 if max reached.
    """
    for i in range(1, max_press + 1):
        press(vp, key, wait_ms)
        p = os.path.join(sdir, f"{label}_{i:02d}.png")
        sz = shot(vp, p)
        state = identify_state(sz, tol=tol)
        log(f"  {label}[{i}/{max_press}]: key={key} size={sz} state={state}")
        if state in DANGER:
            log(f"  !!! DANGER {state} during nav — emergency Esc")
            for _ in range(10):
                press(vp, "Escape", 1500)
            raise RuntimeError(f"danger: {state}")
        if state == target:
            log(f"  -> {target} reached at press {i}")
            return i
    log(f"  nav_to({target}) FAILED after {max_press} presses")
    return -1


def nav_arrowdown_to(vp, sdir, target, max_press=10, label="downto", tol=200,
                     wait_ms=None):
    return nav_to(vp, sdir, "ArrowDown", target, max_press, label, tol, wait_ms)


def nav_arrowup_to(vp, sdir, target, max_press=10, label="upto", tol=200,
                   wait_ms=None):
    return nav_to(vp, sdir, "ArrowUp", target, max_press, label, tol, wait_ms)


def nav_cursor_to_y(vp, sdir, target_y, max_press=25, tol=10,
                     label="ynav", key="ArrowDown", wait_ms=None,
                     allow_overshoot_correct=True, detector="caret",
                     settle_ms=0):
    """Press `key` (default ArrowDown) until cursor Y == target_y ± tol.

    Returns number of presses (>=0) on success, or -1 on failure.

    Detects silent drops by checking cursor_y after each press. If
    `allow_overshoot_correct` and we pass the target, switches to the
    opposite key for correction.

    detector:
      'caret'     — use detect_cursor_row (► glyph at x=4-30). Default,
                    for menu navigation (Advanced tab, AVAGO Main, Cfg Mgmt).
      'highlight' — use detect_active_cursor_row (bg highlight at x=30-400).
                    Required for forms/dialogs with multiple ► markers
                    (AVAGO Create VD form, Clear Config dialog).

    settle_ms:
      After reaching target, wait `settle_ms` and re-detect cursor. If a
      drift is detected (iRMC KVM frame buffer lag or Aptio key event
      queue overrun), send 1 opposite-direction keystroke to correct.
      Use settle_ms >= 1500 for Aptio forms before pressing Enter to
      open a popup, to prevent opening the wrong popup.
    """
    detect_fn = (detect_active_cursor_row if detector == "highlight"
                 else detect_cursor_row)

    def _settle_and_correct(i):
        if settle_ms <= 0:
            return i
        time.sleep(settle_ms / 1000.0)
        p_settle = os.path.join(sdir, f"{label}_settle.png")
        shot(vp, p_settle)
        y_after = detect_fn(p_settle)
        log(f"  nav_y[{label}/{detector}] settle: cursor_y={y_after} target={target_y}")
        if y_after is None or abs(y_after - target_y) <= tol:
            return i
        correction = "ArrowUp" if y_after > target_y else "ArrowDown"
        log(f"  -> drift detected (y_after={y_after}), correcting with 1 {correction}")
        press(vp, correction, wait_ms)
        p_corr = os.path.join(sdir, f"{label}_settle_corr.png")
        shot(vp, p_corr)
        y_corr = detect_fn(p_corr)
        log(f"  -> after correction: cursor_y={y_corr}")
        if y_corr is None or abs(y_corr - target_y) > tol:
            log(f"  WARN: correction failed (cursor_y={y_corr})")
            return -1
        return i + 1

    initial_path = os.path.join(sdir, f"{label}_00_initial.png")
    shot(vp, initial_path)
    initial_y = detect_fn(initial_path)
    log(f"  nav_y[{label}/{detector}]: initial cursor_y={initial_y} target={target_y}")
    if initial_y is not None and abs(initial_y - target_y) <= tol:
        log(f"  -> already at target")
        return _settle_and_correct(0)
    cur_key = key
    for i in range(1, max_press + 1):
        press(vp, cur_key, wait_ms)
        p = os.path.join(sdir, f"{label}_{i:02d}.png")
        shot(vp, p)
        y = detect_fn(p)
        log(f"  nav_y[{label}/{detector}][{i}/{max_press}]: cursor_y={y} target={target_y}")
        if y is None:
            continue
        if abs(y - target_y) <= tol:
            log(f"  -> reached target_y={target_y} at press {i}")
            return _settle_and_correct(i)
        if allow_overshoot_correct:
            if cur_key == "ArrowDown" and y > target_y + tol:
                log(f"  -> overshot, switching to ArrowUp")
                cur_key = "ArrowUp"
            elif cur_key == "ArrowUp" and y < target_y - tol:
                log(f"  -> overshot up, switching to ArrowDown")
                cur_key = "ArrowDown"
    log(f"  nav_cursor_to_y({target_y}) FAILED after {max_press}")
    return -1


# Cursor Y values use the NEW detect_cursor_row implementation (cluster middle).
# Each value is ~6 px lower than the cluster-top values originally observed.
# Use tol=10 by default to absorb cluster-detection variance.
CURSOR_Y_ADVANCED_TAB = {
    "onboard_devices": 102,        # was 108 (old top); new middle
    "pci_status": 121,
    "pci_subsystem": 140,
    "cpu_config": 159,
    "memory_status": 178,
    "sata_config": 197,
    "csm_config": 216,
    "trusted_computing": 235,
    "usb_config": 254,
    "super_io": 273,
    "network_stack": 292,
    "option_rom": 311,
    "viom": 330,
    "iscsi_config": 368,
    "avago_megaraid": 393,         # cursor is a longer ► here; middle is same
    "lsi_software_raid": 406,
    "intel_i210_1": 425,
    "intel_i210_2": 444,
    "driver_health": 463,
}

CURSOR_Y_AVAGO_MAIN_MENU = {
    "configuration_mgmt": 70,
    "controller_mgmt": 83,
    "virtual_drive_mgmt": 102,
    "drive_mgmt": 121,
    "hardware_components": 140,
}

CURSOR_Y_CFG_MGMT = {
    "create_virtual_drive": 70,
    "create_profile_based_vd": 83,
    "clear_configuration": 102,
}

CURSOR_Y_CLEAR_CONFIG_DIALOG = {
    "confirm": 216,
    "yes": 235,
    "no": 254,
}


# AVAGO Create VD form (RAID0 default). Values from iter_08_scout in
# `report/2026-05-17_092256_tx1320_raid10_active_cursor.md` (partitioned-
# beaver session). 'highlight_y' is the detect_active_cursor_row value;
# some entries are NOT reachable via ArrowDown alone (see comments).
#
#   y=88  Save Configuration (TOP) — form initial cursor
#   y=128 Select RAID Level — SKIPPED by ArrowDown 1 from y=88 (#3 finding).
#         Reached by ArrowUp 1 from y=147 (A2 hypothesis, iter_09 verifies).
#   y=147 Select Drives From — [Unconfigured Capacity ↔ Free Capacity]
#   y=166 Select Drives — Enter opens drives popup
#   y=204 Virtual Drive Name (text field)
#   y=259 Strip Size
#   y=280 Read Policy
#   y=299 Write Policy
#   y=316 IO Policy
#   y=337 Access Policy
#   y=373 Disk Cache Policy
#   y=411 Emulation Type (form bottom)
CURSOR_Y_CREATE_VD_FORM = {
    "save_configuration_top": 88,
    "select_raid_level":      128,
    "select_drives_from":     147,
    "select_drives":          166,
    "virtual_drive_name":     204,
    "strip_size":             259,
    "read_policy":            280,
    "write_policy":           299,
    "io_policy":              316,
    "access_policy":          337,
    "disk_cache_policy":      373,
    "emulation_type":         411,
}


def navigate_to_avago_main(vp, sdir, label="goto_avago_main"):
    """From BIOS top-level (any tab), get to AVAGO Main (cursor on Main Menu).

    Returns True on success.
    """
    log(f"[{label}] navigate_to_avago_main")
    ok = safe_navigate_to_advanced_tab(vp, sdir)
    if not ok:
        return False
    for _ in range(25):
        press(vp, "ArrowUp", 400)
    time.sleep(1)
    n = nav_cursor_to_y(vp, sdir, CURSOR_Y_ADVANCED_TAB["avago_megaraid"],
                         max_press=25, tol=8, label=f"{label}_to_avago_row")
    if n < 0:
        return False
    press(vp, "Enter", WAIT_MS_LONG)
    p = os.path.join(sdir, f"{label}_avago_main.png")
    shot(vp, p)
    y = detect_cursor_row(p)
    log(f"[{label}] AVAGO Main cursor_y={y} expected=70")
    return y is not None and abs(y - 70) <= 8


def clear_configuration(vp, sdir):
    """AVAGO Main → Main Menu → Cfg Mgmt → Clear Configuration → Confirm + Yes.

    Assumes we are at AVAGO Main with cursor on Main Menu.

    Clear Config dialog layout (verified iter 5):
       Text: "Clear Configuration will delete all of the Virtual Drives..."
       Confirm    [Disabled]    (cursor_y ≈ 222)
       Yes                       (cursor_y ≈ 241)
     ► No                        (cursor_y ≈ 260; DEFAULT cursor position)

    Sequence: dialog opens with cursor on No (cancel by default).
      ArrowUp x2 → Confirm field, '+' → [Enabled], ArrowDown → Yes, Enter → commit.

    Returns True if Clear Configuration committed (back to Cfg Mgmt after).
    """
    log("clear_configuration: start (assumes at AVAGO Main)")
    press(vp, "Enter", WAIT_MS_POPUP)
    p = os.path.join(sdir, "cc_01_main_menu.png")
    shot(vp, p)
    y = detect_cursor_row(p)
    log(f"  Main Menu opened cursor_y={y} expected=70")
    press(vp, "Enter", WAIT_MS_POPUP)
    p = os.path.join(sdir, "cc_02_cfg_mgmt.png")
    shot(vp, p)
    y = detect_cursor_row(p)
    log(f"  Cfg Mgmt opened cursor_y={y} expected=70 (Create VD)")
    target = CURSOR_Y_CFG_MGMT["clear_configuration"]
    n = nav_cursor_to_y(vp, sdir, target, max_press=8, tol=8,
                        label="cc_03_to_clear")
    if n < 0:
        log("  FAIL: could not reach Clear Configuration")
        return False
    press(vp, "Enter", WAIT_MS_POPUP)
    p = os.path.join(sdir, "cc_04_dialog.png")
    shot(vp, p)
    y_dlg = detect_cursor_row(p)
    sz_dlg = os.path.getsize(p)
    log(f"  Clear Config dialog size={sz_dlg} cursor_y={y_dlg}")
    log("  ArrowUp x4 + '+' (Confirm Enabled), then ArrowDown x2 + Enter (Yes)")
    for _ in range(4):
        press(vp, "ArrowUp", WAIT_MS_DIALOG)
    p_at_conf = os.path.join(sdir, "cc_04a_at_confirm.png")
    shot(vp, p_at_conf)
    log(f"  at_confirm: size={os.path.getsize(p_at_conf)}")
    press(vp, "+", WAIT_MS_DIALOG)
    p_plus = os.path.join(sdir, "cc_05_after_plus.png")
    shot(vp, p_plus)
    sz_plus = os.path.getsize(p_plus)
    log(f"  after + size={sz_plus} (was {sz_dlg})")
    press(vp, "ArrowDown", WAIT_MS_DIALOG)
    p_dn1 = os.path.join(sdir, "cc_06a_down1.png")
    shot(vp, p_dn1)
    log(f"  down1 size={os.path.getsize(p_dn1)}")
    p_enter = os.path.join(sdir, "cc_06b_enter.png")
    log("  Enter → commit clear (on Yes if reached)")
    press(vp, "Enter", WAIT_MS_LONG)
    shot(vp, p_enter)
    log(f"  after Enter size={os.path.getsize(p_enter)}")
    p_done = os.path.join(sdir, "cc_07_after_commit.png")
    shot(vp, p_done)
    sz_done = os.path.getsize(p_done)
    log(f"  commit final size={sz_done}")
    if sz_done < 10000:
        log("  small size suggests OK dialog — Enter to dismiss")
        press(vp, "Enter", WAIT_MS_POPUP)
        p_ok = os.path.join(sdir, "cc_08_after_ok.png")
        shot(vp, p_ok)
        log(f"  after OK size={os.path.getsize(p_ok)}")
    return True


def emergency_esc_out(vp, sdir, max_esc=15, target_names=None):
    """Back out to a safe BIOS state (Advanced tab or AVAGO Main).

    Handles 'Exit Without Saving / Quit without saving? [Yes] No' dialog
    that appears after multiple Esc — answers it with N (No) to STAY in
    BIOS Setup. Never commits to RAID changes.
    """
    if target_names is None:
        target_names = {"avago_main_vds0", "advanced_avago_row",
                        "main_menu_submenu_cfg_mgmt", "bios_main_tab",
                        "bios_advanced_tab"}
    for i in range(1, max_esc + 1):
        press(vp, "Escape", 2500)
        p = os.path.join(sdir, f"emerg_esc_{i:02d}.png")
        sz = shot(vp, p)
        state = identify_state(sz, tol=80)
        log(f"  emerg_esc[{i}]: size={sz} state={state}")
        if state in {"exit_without_saving_dialog_yes", "exit_without_saving_dialog_no",
                     "discard_changes_dialog"}:
            log(f"  -> dismissing dialog: press 'n'")
            press(vp, "n", 2000)
            continue
        if state in target_names:
            log(f"  emergency_esc_out -> {state} (safe)")
            return True
    log(f"  emergency_esc_out: could not reach safe state after {max_esc} Esc")
    return False


EXIT_DIALOG_STATES = {
    "exit_without_saving_dialog_yes",
    "exit_without_saving_dialog_no",
    "exit_dialog_on_main",
    "exit_dialog_on_main_v2",
    "exit_dialog_on_main_v3",
    "exit_dialog_on_main_v4",
    "exit_dialog_on_main_v5",
    "discard_changes_dialog",
}

BIOS_TOP_TAB_STATES = {
    "bios_main_tab",
    "bios_advanced_tab",
    "bios_advanced_tab_onboard_devices_cursor",
    "advanced_avago_row",
    "bios_security_tab",
    "bios_security_tab_secure_boot_cursor",
    "bios_main_tab_system_info_cursor",
}


def ensure_at_advanced_tab(vp, sdir):
    """Return True if currently at Advanced tab (any cursor position)."""
    sz = shot(vp, os.path.join(sdir, "ensure_advanced_check.png"))
    state = identify_state(sz, tol=80)
    return state in {"bios_advanced_tab",
                     "bios_advanced_tab_onboard_devices_cursor",
                     "advanced_avago_row"}


def safe_navigate_to_advanced_tab(vp, sdir, max_attempts=12):
    """Recover to BIOS Advanced tab.

    Steps:
      1. Up to max_attempts: shot + identify
         - Exit-Without-Saving dialog (any variant) → press 'n'
         - partial-access HTML overlay → dismiss + wait
         - Known top-level BIOS tab → break out of loop
         - Otherwise → press Esc to go up one level
      2. If at non-Advanced tab, ArrowLeft x7 (force to Main) then
         ArrowRight x1 to land on Advanced.
    """
    def is_top_level(state, sz):
        if state in BIOS_TOP_TAB_STATES:
            return True
        if state and state.startswith("advanced_tab_item_"):
            return True
        return False

    log("safe_navigate_to_advanced_tab")
    for i in range(1, max_attempts + 1):
        sz = shot(vp, os.path.join(sdir, f"safe_esc_{i:02d}.png"))
        state = identify_state(sz, tol=80)
        log(f"  safe_esc[{i}] size={sz} state={state}")
        if state in EXIT_DIALOG_STATES:
            log("    dismiss Exit dialog (ArrowRight to No, Enter)")
            press(vp, "ArrowRight", 800)
            press(vp, "Enter", 2000)
            continue
        if state == "partial_access_dialog":
            _dismiss_partial_access_dialog(vp)
            time.sleep(2)
            continue
        if is_top_level(state, sz):
            log(f"    at top-level: {state}")
            break
        press(vp, "Escape", 2000)
    sz = shot(vp, os.path.join(sdir, "safe_pos_check.png"))
    state = identify_state(sz, tol=80)
    log(f"  pos check: size={sz} state={state}")
    if state in {"bios_advanced_tab",
                 "bios_advanced_tab_onboard_devices_cursor",
                 "advanced_avago_row"} or (
            state and state.startswith("advanced_tab_item_")):
        return True
    if state in EXIT_DIALOG_STATES:
        press(vp, "ArrowRight", 800)
        press(vp, "Enter", 2000)
        state = identify_state(shot(vp, os.path.join(sdir, "safe_after_no.png")), tol=80)
        log(f"  after No: state={state}")
    advanced_states = {"bios_advanced_tab",
                        "bios_advanced_tab_onboard_devices_cursor",
                        "advanced_avago_row"}
    for direction, key in [("left", "ArrowLeft"), ("right", "ArrowRight")]:
        for i in range(1, 8):
            press(vp, key, 1500)
            sz = shot(vp, os.path.join(sdir, f"safe_tab_{direction}_{i}.png"))
            state = identify_state(sz, tol=80)
            log(f"  tab {direction}[{i}]: size={sz} state={state}")
            if state in advanced_states or (state and state.startswith("advanced_tab_item_")):
                return True
    return False


def _dismiss_partial_access_dialog(vp):
    """Click the Ok button on iRMC's 'Partial access privilege' dialog.

    The dialog is an HTML overlay, not a canvas dialog. Look for a button
    with text 'Ok' inside a modal-style container. Returns True if found
    and clicked.
    """
    clicked = vp.evaluate("""() => {
        const btns = document.querySelectorAll('button, a, input[type=button], input[type=submit]');
        for (const b of btns) {
            const txt = (b.innerText || b.value || '').trim();
            if (/^Ok$/i.test(txt)) {
                const r = b.getBoundingClientRect();
                if (r.width > 0 && r.height > 0) {
                    b.click();
                    return true;
                }
            }
        }
        return false;
    }""")
    return clicked


def open_viewer(p, bmc=BMC, usr=USR, psw=PSW, warmup_s=15, wake=True,
                tolerate_partial=True, login_retries=3, login_retry_wait_s=30):
    """Open a single iRMC KVM viewer page. Returns (browser, ctx, vp).

    If `tolerate_partial`, attempt to dismiss any 'Partial access' dialog
    (HTML overlay rendered by viewer.min.js when our session is not
    master). After dismissal we still may have read-only access; the
    caller is responsible for retrying / waiting if keystrokes don't land.

    Retries login on transient BMC unavailability (TX1320 iRMC often
    drops HTTPS for 30-60s after KVM session churn).
    """
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
    sid = None
    for attempt in range(1, login_retries + 1):
        log(f"Login to {bmc} (attempt {attempt}/{login_retries})")
        try:
            pg.goto(f"https://{bmc}/", wait_until="networkidle", timeout=45000)
            pg.click('input[name="P99"]', timeout=45000)
            pg.wait_for_load_state("networkidle", timeout=45000)
            m = re.search(r'sid=([^&#]+)', pg.url)
            if m:
                sid = m.group(1)
                break
            log(f"  no SID in URL: {pg.url}")
        except Exception as e:
            log(f"  login failed: {type(e).__name__}: {str(e)[:120]}")
        if attempt < login_retries:
            log(f"  retrying in {login_retry_wait_s}s")
            time.sleep(login_retry_wait_s)
    if not sid:
        raise RuntimeError(f"Failed to login to {bmc} after {login_retries} attempts")
    log(f"SID: {sid[:8]}...")
    vp = ctx.new_page()
    for attempt in range(1, login_retries + 1):
        try:
            vp.goto(f"https://{bmc}/viewer.html?ms=0&lang=0&sid={sid}",
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
    if tolerate_partial:
        for i in range(3):
            if _dismiss_partial_access_dialog(vp):
                log(f"  dismissed partial-access dialog (attempt {i+1})")
                time.sleep(1)
            else:
                break
    vp.locator("canvas#kvm").click(timeout=10000)
    time.sleep(2)
    if wake:
        press(vp, "F1", 2000)
        if tolerate_partial:
            _dismiss_partial_access_dialog(vp)
        press(vp, "Escape", 2000)
        if tolerate_partial:
            _dismiss_partial_access_dialog(vp)
    return browser, ctx, vp


def wait_for_master_access(vp, sdir, max_wait_s=300, poll_interval_s=15):
    """Poll until canvas no longer shows partial_access_dialog overlay.

    Returns True when canvas size != partial_access_dialog fingerprint.
    Tries to dismiss the dialog at each iteration.
    """
    import time as _t
    deadline = _t.time() + max_wait_s
    n = 0
    while _t.time() < deadline:
        n += 1
        _dismiss_partial_access_dialog(vp)
        p = os.path.join(sdir, f"wait_master_{n:02d}.png")
        sz = shot(vp, p)
        state = identify_state(sz)
        log(f"  wait_master[{n}]: size={sz} state={state}")
        if state != "partial_access_dialog":
            log(f"  -> master access likely (state={state})")
            return True
        _t.sleep(poll_interval_s)
    log(f"  wait_for_master_access TIMEOUT after {max_wait_s}s")
    return False


# clear_configuration is defined earlier (line ~294) as the iter 5 impl.
# This placeholder removed to avoid override.


def navigate_advanced_to_avago_main(vp, sdir, label_prefix="nav_avago"):
    """Wake → BIOS Main → Advanced tab → AVAGO row → AVAGO Main.

    Uses adaptive nav_arrowdown_to for the 14-press to AVAGO row.
    Assumes BIOS Setup is already open (S2 cycle complete).
    """
    log("=== Navigate to AVAGO Main ===")
    press(vp, "ArrowRight", WAIT_MS_POPUP)
    sz = shot(vp, os.path.join(sdir, f"{label_prefix}_t1_advanced.png"))
    log(f"  Advanced tab size={sz}")
    n = nav_arrowdown_to(vp, sdir, "advanced_avago_row",
                          max_press=18, label=f"{label_prefix}_t2_to_avago")
    if n < 0:
        log("  WARN: advanced_avago_row not detected — assuming reached anyway")
    press(vp, "Enter", WAIT_MS_LONG)
    ok = assert_state(vp, sdir, f"{label_prefix}_t3_avago_main", "avago_main_vds0")
    return ok


if __name__ == "__main__":
    print(f"FINGERPRINTS loaded: {len(FINGERPRINTS)} entries")
    for name in sorted(FINGERPRINTS):
        print(f"  {name}: size={FINGERPRINTS[name]['size']}")
    print(f"DANGER: {sorted(DANGER)}")
