#!/usr/bin/env python3
"""Fujitsu iRMC S4 BIOS settings management via WinSCU XML.

Wraps the OEM Redfish actions on /redfish/v1/Systems/0/Bios:
  FTSBios.BSPBRBackup            : request backup (runs at next BIOS boot phase)
  FTSBios.BSPBRSaveBackupToFile  : download the backup XML
  FTSBios.BSPBRRestore           : restore from XML (applies at next BIOS boot phase)
  FTSBios.BSPBRBackup status     : via /redfish/v1/TaskService/Tasks/<n>

Subcommands:
  backup  <out.xml>        Trigger backup, poll task, download XML
  restore <in.xml>         Trigger restore, poll task
  show    <xml> [regex]    Show <supportedSetting> entries (filter id/name by regex)
  set     <xml> <id> <value>
                           Update a <supportedSetting>'s <value> (in-place)
  diff    <a.xml> <b.xml>  Show differences between two backups
  apply-config <config.yml> [--restore-now]
                           Read config['bios_settings'], edit the on-server snapshot
                           and (optionally) restore it
"""
import argparse
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
import ssl
import base64
import json
import subprocess

# Re-exec under .venv if available (consistent with sibling scripts)
VENV_PYTHON = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ".venv", "bin", "python"
)
if os.path.exists(VENV_PYTHON) and sys.executable != VENV_PYTHON:
    os.execv(VENV_PYTHON, [VENV_PYTHON] + sys.argv)


# iRMC S4 needs old DH suites; the easiest is to disable SSL verification AND
# allow the legacy cipher set via OPENSSL_CONF or curl. urllib doesn't easily
# expose SECLEVEL=0, so we shell out to curl for HTTPS Redfish calls.

CURL_BASE = [
    "curl", "-sS", "-k",
    "--ciphers", "DEFAULT@SECLEVEL=0",
    "--max-time", "120",
]


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def curl(method, url, user, pwd, *, headers=None, data=None,
         data_file=None, output=None, extra=None, want_status=False):
    """Run curl. Returns (status_code, body_bytes)."""
    cmd = list(CURL_BASE)
    cmd += ["-u", f"{user}:{pwd}"]
    cmd += ["-X", method]
    if headers:
        for h in headers:
            cmd += ["-H", h]
    if data is not None:
        cmd += ["--data-binary", data]
    if data_file is not None:
        cmd += ["--data-binary", f"@{data_file}"]
    if output is not None:
        cmd += ["-o", output]
    if want_status:
        cmd += ["-w", "HTTP_STATUS=%{http_code}\n"]
    if extra:
        cmd += list(extra)
    cmd += [url]
    res = subprocess.run(cmd, capture_output=True)
    body = res.stdout
    status = None
    if want_status:
        # the last line of stdout is HTTP_STATUS=xxx (when -w used)
        m = re.search(rb'HTTP_STATUS=(\d+)\s*$', body)
        if m:
            status = int(m.group(1))
            body = body[:m.start()].rstrip(b"\n")
    return status, body


def get_json(url, user, pwd):
    _status, body = curl("GET", url, user, pwd)
    try:
        return json.loads(body.decode("utf-8"))
    except Exception as e:
        log(f"WARN: not JSON ({e}): {body[:200]!r}")
        return None


def get_task_state(bmc, user, pwd, task_id):
    j = get_json(f"https://{bmc}/redfish/v1/TaskService/Tasks/{task_id}",
                 user, pwd)
    if j is None:
        return None, None, None
    state = j.get("TaskState")
    pct = (j.get("Oem", {}).get("ts_fujitsu", {})
              .get("StateProgressPercent"))
    status_oem = (j.get("Oem", {}).get("ts_fujitsu", {})
                     .get("StatusOEM"))
    msgs = (j.get("Oem", {}).get("ts_fujitsu", {})
              .get("MessagesOEM", []))
    return state, pct, (status_oem, msgs)


def wait_for_task(bmc, user, pwd, task_url, *, deadline_sec=900,
                  poll_sec=5):
    """Poll until task reaches a terminal state. Returns final task dict.

    Note: BSPBR tasks require a BIOS boot phase to execute, so a host reboot
    is typically required between trigger and completion. The caller is
    responsible for triggering the reboot if needed.
    """
    task_id = task_url.rsplit("/", 1)[-1]
    log(f"Polling Task /{task_id} (timeout={deadline_sec}s)")
    deadline = time.time() + deadline_sec
    last_oem_state = ""
    last_msg = ""
    while time.time() < deadline:
        state, pct, info = get_task_state(bmc, user, pwd, task_id)
        if state is None:
            time.sleep(poll_sec)
            continue
        oem_status = info[0] if info else ""
        msgs = info[1] if info else []
        latest = msgs[-1] if msgs else ""
        if oem_status != last_oem_state or latest != last_msg:
            log(f"  state={state} pct={pct} oem={oem_status} msg={latest!r}")
            last_oem_state = oem_status
            last_msg = latest
        if state in ("Completed", "Exception", "Killed", "Cancelled"):
            return state, oem_status, msgs
        time.sleep(poll_sec)
    return None, "Timeout", []


def cmd_backup(args):
    bmc, user, pwd = args.bmc_ip, args.bmc_user, args.bmc_pass
    log(f"POST BSPBRBackup at https://{bmc}/...")
    status, body = curl(
        "POST",
        f"https://{bmc}/redfish/v1/Systems/0/Bios/Actions/Oem/FTSBios.BSPBRBackup",
        user, pwd,
        headers=["Content-Type: application/json"],
        data="{}",
        want_status=True,
        extra=["-D", "-"],  # include response headers in stdout
    )
    log(f"BSPBRBackup POST -> HTTP {status}")
    # Find Location header for task URL
    task_url = None
    for line in body.splitlines():
        line = line.decode("utf-8", "ignore")
        m = re.match(r'(?i)Location:\s*(\S+)', line)
        if m:
            task_url = m.group(1).strip()
            break
    if task_url:
        log(f"Task URL: {task_url}")
    else:
        # Sometimes already-completed; try IsBspbrFileAvailable directly
        log("No Location header; will check availability directly")

    if not args.skip_wait:
        if task_url:
            state, oem_status, msgs = wait_for_task(
                bmc, user, pwd, task_url,
                deadline_sec=args.task_timeout,
            )
            log(f"Task final: state={state} oem={oem_status} msgs={msgs}")
        else:
            # Just wait for IsBspbrFileAvailable
            log("Waiting for IsBspbrFileAvailable")
            deadline = time.time() + args.task_timeout
            while time.time() < deadline:
                j = get_json(f"https://{bmc}/redfish/v1/Systems/0/Bios",
                             user, pwd)
                if (j and j.get("Oem", {}).get("ts_fujitsu", {})
                          .get("IsBspbrFileAvailable")):
                    break
                time.sleep(5)

    log(f"GET BSPBRSaveBackupToFile -> {args.output}")
    status, _ = curl(
        "POST",
        f"https://{bmc}/redfish/v1/Systems/0/Bios/Actions/Oem/"
        "FTSBios.BSPBRSaveBackupToFile",
        user, pwd,
        headers=["Content-Type: application/json"],
        data="{}",
        output=args.output,
        want_status=True,
    )
    log(f"Download HTTP {status} -> {args.output}")
    if status != 200:
        sys.exit(1)
    sz = os.path.getsize(args.output)
    log(f"Saved {args.output} ({sz} bytes)")


def cmd_restore(args):
    bmc, user, pwd = args.bmc_ip, args.bmc_user, args.bmc_pass
    log(f"POST BSPBRRestore from {args.input}")
    # iRMC accepts BSPBR XML as multipart/form-data with field name "data".
    # Other Content-Types are rejected with 406 / ContentTypeNotSupported.
    status, body = curl(
        "POST",
        f"https://{bmc}/redfish/v1/Systems/0/Bios/Actions/Oem/FTSBios.BSPBRRestore",
        user, pwd,
        extra=["-F", f"data=@{args.input}", "-D", "-"],
        want_status=True,
    )
    log(f"BSPBRRestore POST -> HTTP {status}")
    # Print body for debugging
    for line in body.splitlines()[:50]:
        log(f"  {line.decode('utf-8', 'ignore')}")
    if status not in (200, 202):
        sys.exit(1)
    task_url = None
    for line in body.splitlines():
        s = line.decode("utf-8", "ignore")
        m = re.match(r'(?i)Location:\s*(\S+)', s)
        if m:
            task_url = m.group(1).strip()
            break
    if task_url and not args.skip_wait:
        state, oem_status, msgs = wait_for_task(
            bmc, user, pwd, task_url,
            deadline_sec=args.task_timeout,
        )
        log(f"Task final: state={state} oem={oem_status} msgs={msgs}")
        if state != "Completed":
            sys.exit(2)


def parse_xml(path):
    with open(path, "rb") as f:
        text = f.read()
    # iRMC BSPBR backup includes trailing NUL bytes (0x00) that break ET.
    text = text.rstrip(b"\x00\r\n\t ")
    return ET.ElementTree(ET.fromstring(text))


def write_xml(tree, path):
    # Preserve XML declaration and force utf-8.
    tree.write(path, encoding="utf-8", xml_declaration=True)


def iter_supported(tree):
    """Yield <supportedSetting> elements."""
    root = tree.getroot()
    for ss in root.iter("supportedSetting"):
        yield ss


def supp_id(ss):
    e = ss.find("id")
    return e.text.strip() if e is not None and e.text else ""


def supp_name(ss):
    e = ss.find("name")
    return e.text.strip() if e is not None and e.text else ""


def supp_value(ss):
    e = ss.find("value")
    return e.text.strip() if e is not None and e.text else ""


def cmd_show(args):
    tree = parse_xml(args.xml)
    pat = re.compile(args.filter or ".", re.IGNORECASE)
    matched = 0
    for ss in iter_supported(tree):
        sid = supp_id(ss)
        name = supp_name(ss)
        val = supp_value(ss)
        if pat.search(sid) or pat.search(name):
            print(f"{sid:40s} | {name:40s} | {val}")
            matched += 1
    if matched == 0:
        log(f"No supportedSetting matched filter: {args.filter!r}")


def cmd_set(args):
    tree = parse_xml(args.xml)
    found = False
    for ss in iter_supported(tree):
        if supp_id(ss) == args.id:
            v = ss.find("value")
            if v is None:
                v = ET.SubElement(ss, "value")
            old = v.text
            v.text = args.value
            log(f"set {args.id}: {old!r} -> {args.value!r}")
            found = True
            break
    if not found:
        log(f"id {args.id!r} not found in {args.xml}")
        sys.exit(2)
    write_xml(tree, args.xml)


def cmd_diff(args):
    a = {supp_id(s): supp_value(s) for s in iter_supported(parse_xml(args.a))}
    b = {supp_id(s): supp_value(s) for s in iter_supported(parse_xml(args.b))}
    all_ids = sorted(set(a) | set(b))
    changed = 0
    for sid in all_ids:
        if a.get(sid) != b.get(sid):
            print(f"{sid:40s} | {a.get(sid)!r} -> {b.get(sid)!r}")
            changed += 1
    log(f"Total changed: {changed}")


def cmd_apply_config(args):
    """Read config['bios_settings'] map and apply to the latest backup."""
    cfg_path = args.config
    # Lightweight YAML: use the project's yq for keys we know
    yq = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "bin", "yq")

    def yq_get(path):
        r = subprocess.run([yq, path, cfg_path], capture_output=True, text=True)
        return (r.stdout or "").strip()

    bmc = yq_get(".bmc_ip")
    user = yq_get(".bmc_user")
    pwd = yq_get(".bmc_pass")
    args.bmc_ip, args.bmc_user, args.bmc_pass = bmc, user, pwd
    args.task_timeout = 1800
    args.skip_wait = False

    workdir = os.path.dirname(os.path.abspath(args.workdir))
    os.makedirs(args.workdir, exist_ok=True)
    pre_xml = os.path.join(args.workdir, "bios-pre.xml")
    edit_xml = os.path.join(args.workdir, "bios-edit.xml")
    log(f"Backup current BIOS -> {pre_xml}")
    args.output = pre_xml
    cmd_backup(args)
    import shutil
    shutil.copy(pre_xml, edit_xml)

    # Read intended map: each key under bios_settings.supported is id -> value
    # (avoids relying on yq for nested maps)
    # Use Python yaml if present, otherwise a tiny inline parser
    try:
        import yaml as _yaml  # type: ignore
        with open(cfg_path) as f:
            cfg = _yaml.safe_load(f)
    except Exception as e:
        log(f"yaml load failed ({e}); falling back to manual ids")
        cfg = {}
    bios_settings = (cfg or {}).get("bios_settings", {}) if cfg else {}
    supported_map = bios_settings.get("supported", {})
    if not supported_map:
        log("No bios_settings.supported in config; nothing to change")
        return

    tree = parse_xml(edit_xml)
    changes = 0
    for sid, target in supported_map.items():
        for ss in iter_supported(tree):
            if supp_id(ss) == sid:
                v = ss.find("value")
                if v is None:
                    v = ET.SubElement(ss, "value")
                old = v.text
                if (old or "") != str(target):
                    log(f"set {sid}: {old!r} -> {target!r}")
                    v.text = str(target)
                    changes += 1
                break
        else:
            log(f"WARN: id {sid!r} not found in backup XML")
    if changes == 0:
        log("No changes needed; XML already matches config")
        return
    write_xml(tree, edit_xml)
    log(f"Wrote {changes} change(s) to {edit_xml}")

    if args.restore_now:
        args.input = edit_xml
        cmd_restore(args)
    else:
        log("Skipping restore (use --restore-now). Edited XML at: "
            + edit_xml)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bmc-ip", default=None)
    p.add_argument("--bmc-user", default=None)
    p.add_argument("--bmc-pass", default=None)
    p.add_argument("--task-timeout", type=int, default=900)
    p.add_argument("--skip-wait", action="store_true",
                   help="Don't wait for task completion (caller will reboot)")

    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("backup")
    sp.add_argument("output")
    sp.set_defaults(func=cmd_backup)

    sp = sub.add_parser("restore")
    sp.add_argument("input")
    sp.set_defaults(func=cmd_restore)

    sp = sub.add_parser("show")
    sp.add_argument("xml")
    sp.add_argument("filter", nargs="?", default=None)
    sp.set_defaults(func=cmd_show)

    sp = sub.add_parser("set")
    sp.add_argument("xml")
    sp.add_argument("id")
    sp.add_argument("value")
    sp.set_defaults(func=cmd_set)

    sp = sub.add_parser("diff")
    sp.add_argument("a")
    sp.add_argument("b")
    sp.set_defaults(func=cmd_diff)

    sp = sub.add_parser("apply-config")
    sp.add_argument("config")
    sp.add_argument("--workdir", default="tmp/biosraid")
    sp.add_argument("--restore-now", action="store_true")
    sp.set_defaults(func=cmd_apply_config)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
