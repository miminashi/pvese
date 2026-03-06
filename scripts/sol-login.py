#!/usr/bin/env python3
"""SOL login with boot-stage-aware state machine.

Connects to BMC via SOL, detects boot stages (GRUB, kernel, systemd),
waits for login prompt, and optionally executes commands.

Exit codes:
  0 = success
  1 = login timeout
  2 = command execution failure
  3 = connection error
"""
import argparse
import os
import signal
import subprocess
import sys
import time

try:
    import pexpect
except ImportError:
    print("ERROR: pexpect not installed. Run: pip3 install pexpect", file=sys.stderr)
    sys.exit(3)


# --- Boot stage definitions ---

STAGE_DETECTING = "DETECTING"
STAGE_GRUB_MENU = "GRUB_MENU"
STAGE_KERNEL_BOOT = "KERNEL_BOOT"
STAGE_SYSTEMD_INIT = "SYSTEMD_INIT"
STAGE_LOGIN_PROMPT = "LOGIN_PROMPT"
STAGE_LOGGED_IN = "LOGGED_IN"


def log(msg):
    """Log to stderr with timestamp."""
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def deactivate_sol(bmc_ip, bmc_user, bmc_pass):
    """Deactivate any existing SOL session."""
    cmd = [
        "ipmitool", "-I", "lanplus",
        "-H", bmc_ip, "-U", bmc_user, "-P", bmc_pass,
        "sol", "deactivate",
    ]
    try:
        subprocess.run(cmd, capture_output=True, timeout=10)
    except Exception:
        pass


def sol_connect(bmc_ip, bmc_user, bmc_pass):
    """Spawn ipmitool SOL connection."""
    cmd = (
        f"ipmitool -I lanplus -H {bmc_ip} -U {bmc_user} -P {bmc_pass} sol activate"
    )
    child = pexpect.spawn(cmd, timeout=30, encoding="latin-1")
    return child


def detect_stage(output):
    """Detect boot stage from SOL output text.

    Returns (new_stage, reason) or (None, None) if no stage detected.
    """
    # Order matters: check more specific patterns first
    if "GNU GRUB" in output or "grub>" in output:
        return STAGE_GRUB_MENU, "GRUB menu detected"
    if "login:" in output:
        return STAGE_LOGIN_PROMPT, "login prompt detected"
    if "systemd[1]:" in output or "Started " in output:
        return STAGE_SYSTEMD_INIT, "systemd init detected"
    if "Loading Linux" in output or "Booting " in output or "[    0." in output:
        return STAGE_KERNEL_BOOT, "kernel boot detected"
    return None, None


def wait_for_login(child, timeout, hostname_hint=""):
    """State machine: wait through boot stages until login prompt.

    Returns:
      "login" if login prompt reached (need to authenticate)
      "shell" if already at a root shell prompt (already logged in)
      None on timeout
    """
    stage = STAGE_DETECTING
    stage_entered = time.time()
    start = time.time()
    detect_enter_sent = 0  # count of Enter presses in DETECTING

    log(f"Stage: {stage} (timeout={timeout}s)")

    while time.time() - start < timeout:
        remaining = timeout - (time.time() - start)
        if remaining <= 0:
            break

        # Per-stage poll interval
        if stage == STAGE_GRUB_MENU:
            poll_timeout = 5
        elif stage == STAGE_KERNEL_BOOT:
            poll_timeout = 3
        elif stage == STAGE_SYSTEMD_INIT:
            poll_timeout = 3
        else:
            poll_timeout = 5

        poll_timeout = min(poll_timeout, remaining)

        try:
            # Build expect patterns based on current stage
            patterns = [pexpect.TIMEOUT, pexpect.EOF]
            # Always look for login prompt and shell prompt
            patterns.append("login:")    # idx 2
            patterns.append("root@")     # idx 3 - already logged in

            if stage == STAGE_DETECTING:
                patterns.extend(["GNU GRUB", "grub>",       # idx 4, 5
                                 "Loading Linux", "Booting ",  # idx 6, 7
                                 r"\[\s+\d+\.",              # idx 8
                                 "systemd\\[1\\]:"])           # idx 9
            elif stage == STAGE_GRUB_MENU:
                patterns.extend(["Loading Linux", "Booting ",  # idx 4, 5
                                 r"\[\s+\d+\.",              # idx 6
                                 "systemd\\[1\\]:"])           # idx 7
            elif stage == STAGE_KERNEL_BOOT:
                patterns.extend(["systemd\\[1\\]:", "Started "])  # idx 4, 5
            elif stage == STAGE_SYSTEMD_INIT:
                pass  # login: and root@ are already in patterns

            idx = child.expect(patterns, timeout=poll_timeout)

            if idx == 0:  # TIMEOUT
                elapsed_in_stage = time.time() - stage_entered
                if stage == STAGE_DETECTING:
                    # Send Enter periodically to elicit login prompt
                    if elapsed_in_stage > 10 and detect_enter_sent < 10:
                        log("DETECTING: sending Enter to probe")
                        child.sendline("")
                        detect_enter_sent += 1
                elif stage == STAGE_GRUB_MENU:
                    log(f"GRUB_MENU: waiting for auto-boot "
                        f"({elapsed_in_stage:.0f}s, NO keys sent)")
                elif stage == STAGE_SYSTEMD_INIT:
                    # Periodically send Enter to catch login prompt
                    if elapsed_in_stage > 15:
                        log("SYSTEMD_INIT: sending Enter to probe for login")
                        child.sendline("")
                continue

            if idx == 1:  # EOF
                log("SOL connection lost (EOF)")
                return None

            if idx == 2:  # login:
                old_stage = stage
                stage = STAGE_LOGIN_PROMPT
                log(f"Stage: {old_stage} -> {stage}")
                return "login"

            if idx == 3:  # root@ (already logged in)
                log(f"Stage: {stage} -> LOGGED_IN (shell prompt detected)")
                return "shell"

            # Stage-specific pattern matches (idx >= 4)
            if stage == STAGE_DETECTING:
                if idx == 4 or idx == 5:  # GNU GRUB or grub>
                    stage = STAGE_GRUB_MENU
                    stage_entered = time.time()
                    log(f"Stage: DETECTING -> {stage}")
                elif idx == 6 or idx == 7 or idx == 8:  # Loading Linux, Booting, [  0.
                    stage = STAGE_KERNEL_BOOT
                    stage_entered = time.time()
                    log(f"Stage: DETECTING -> {stage}")
                elif idx == 9:  # systemd[1]:
                    stage = STAGE_SYSTEMD_INIT
                    stage_entered = time.time()
                    log(f"Stage: DETECTING -> {stage}")

            elif stage == STAGE_GRUB_MENU:
                if idx == 4 or idx == 5 or idx == 6:  # Loading Linux, Booting, [ 0.
                    stage = STAGE_KERNEL_BOOT
                    stage_entered = time.time()
                    log(f"Stage: GRUB_MENU -> {stage}")
                elif idx == 7:  # systemd[1]:
                    stage = STAGE_SYSTEMD_INIT
                    stage_entered = time.time()
                    log(f"Stage: GRUB_MENU -> {stage}")

            elif stage == STAGE_KERNEL_BOOT:
                if idx == 4 or idx == 5:  # systemd[1]: or Started
                    stage = STAGE_SYSTEMD_INIT
                    stage_entered = time.time()
                    log(f"Stage: KERNEL_BOOT -> {stage}")

        except pexpect.TIMEOUT:
            continue
        except pexpect.EOF:
            log("SOL connection lost (EOF)")
            return None

    log(f"Timeout reached ({timeout}s) in stage {stage}")
    return None


def do_login(child, root_pass):
    """Send root credentials at login prompt. Returns True on success."""
    log("Sending 'root' username")
    child.sendline("root")

    try:
        idx = child.expect(["Password:", "assword:", pexpect.TIMEOUT], timeout=10)
        if idx == 2:
            log("No password prompt received")
            return False
    except (pexpect.TIMEOUT, pexpect.EOF):
        log("No password prompt received")
        return False

    log("Sending password")
    child.sendline(root_pass)

    try:
        idx = child.expect(
            ["root@", "# ", "Login incorrect", "login:", pexpect.TIMEOUT],
            timeout=15,
        )
        if idx == 0 or idx == 1:
            log("Login successful")
            return True
        elif idx == 2 or idx == 3:
            log("Login incorrect")
            return False
        else:
            log("Login timeout")
            return False
    except (pexpect.TIMEOUT, pexpect.EOF):
        log("Login failed (timeout/EOF)")
        return False


def run_command(child, cmd, timeout=30):
    """Execute a single command over SOL. Returns (success, output)."""
    # Use a unique marker to detect command completion
    marker = f"__SOLCMD_{os.getpid()}__"
    child.sendline(cmd)
    time.sleep(0.3)
    child.sendline(f"echo {marker}=$?")

    try:
        idx = child.expect([f"{marker}=", pexpect.TIMEOUT], timeout=timeout)
        if idx == 0:
            # Read the exit code
            child.expect(["\r\n", "\n", pexpect.TIMEOUT], timeout=3)
            output = child.before.strip()
            # Try to parse exit code
            try:
                rc = int(output)
            except (ValueError, TypeError):
                rc = 0
            return rc == 0, child.before
        else:
            log(f"Command timeout: {cmd}")
            return False, ""
    except pexpect.EOF:
        log("Connection lost during command execution")
        return False, ""
    except pexpect.TIMEOUT:
        log(f"Command timeout: {cmd}")
        return False, ""


def run_commands_file(child, commands_file):
    """Execute commands from file. Returns True if all succeed."""
    try:
        with open(commands_file, "r") as f:
            commands = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    except FileNotFoundError:
        log(f"Commands file not found: {commands_file}")
        return False

    log(f"Executing {len(commands)} commands from {commands_file}")
    all_ok = True
    for i, cmd in enumerate(commands, 1):
        log(f"[{i}/{len(commands)}] {cmd}")
        ok, _ = run_command(child, cmd)
        if not ok:
            log(f"Command may have failed: {cmd}")
            # Continue executing remaining commands
            all_ok = False
        time.sleep(0.1)

    return all_ok


def disconnect_sol(child, logged_in=False):
    """Cleanly disconnect SOL session."""
    try:
        if logged_in:
            child.sendline("exit")
            time.sleep(1)
        child.send("~.")
        time.sleep(2)
        child.close()
    except Exception:
        pass


def main():
    parser = argparse.ArgumentParser(
        description="SOL login with boot-stage detection"
    )
    parser.add_argument("--bmc-ip", required=True, help="BMC IP address")
    parser.add_argument("--bmc-user", required=True, help="BMC username")
    parser.add_argument("--bmc-pass", required=True, help="BMC password")
    parser.add_argument("--root-pass", required=True, help="Root password for login")
    parser.add_argument("--commands-file", help="File with commands to execute (one per line)")
    parser.add_argument("--timeout", type=int, default=180, help="Overall timeout in seconds (default: 180)")
    parser.add_argument("--check-only", action="store_true", help="Only verify login, do not execute commands")
    args = parser.parse_args()

    # Deactivate any stale SOL session
    log("Deactivating any existing SOL session")
    deactivate_sol(args.bmc_ip, args.bmc_user, args.bmc_pass)
    time.sleep(2)

    # Connect
    log(f"Connecting SOL to {args.bmc_ip}")
    try:
        child = sol_connect(args.bmc_ip, args.bmc_user, args.bmc_pass)
    except Exception as e:
        log(f"Connection failed: {e}")
        sys.exit(3)

    # Send initial Enter after short delay to elicit output
    time.sleep(3)
    child.sendline("")

    # Wait for login prompt through boot stages
    result = wait_for_login(child, args.timeout)
    if result is None:
        log("Failed to reach login prompt")
        disconnect_sol(child)
        sys.exit(1)

    if result == "login":
        # Need to authenticate
        if not do_login(child, args.root_pass):
            log("Login failed")
            disconnect_sol(child)
            sys.exit(1)
    elif result == "shell":
        log("Already at shell prompt, skipping login")

    log("Stage: LOGGED_IN")

    if args.check_only:
        log("Check-only mode: login verified, disconnecting")
        disconnect_sol(child, logged_in=True)
        sys.exit(0)

    # Execute commands
    if args.commands_file:
        ok = run_commands_file(child, args.commands_file)
        disconnect_sol(child, logged_in=True)
        if not ok:
            log("Some commands may have failed")
            sys.exit(2)
    else:
        log("No commands file specified, disconnecting")
        disconnect_sol(child, logged_in=True)

    log("All done")
    sys.exit(0)


if __name__ == "__main__":
    main()
