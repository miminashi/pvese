#!/usr/bin/env python3
"""Passive SOL monitor for Debian installer progress tracking.

Connects to BMC via SOL and monitors installer output without sending
any keystrokes. Detects installer stages and waits for power-off.

Exit codes:
  0 = completed (PowerState Off)
  1 = timeout
  2 = connection error
  3 = abnormal termination
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
    sys.exit(2)


# --- Installer stage definitions ---

INSTALLER_STAGES = [
    ("Loading additional components",   "LOADING_COMPONENTS"),
    ("Detecting network hardware",      "DETECTING_NETWORK"),
    ("Retrieving preseed file",         "RETRIEVING_PRESEED"),
    ("Installing the base system",      "INSTALLING_BASE"),
    ("Configuring apt",                 "CONFIGURING_APT"),
    ("Select and install software",     "INSTALLING_SOFTWARE"),
    ("Installing GRUB",                 "INSTALLING_GRUB"),
    ("Installation complete",           "INSTALL_COMPLETE"),
    ("Power down",                      "POWER_DOWN"),
]


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


def disconnect_sol(child):
    """Cleanly disconnect SOL session (no login/logout needed)."""
    try:
        child.send("~.")
        time.sleep(2)
        child.close()
    except Exception:
        pass


def check_powerstate(bmc_ip, bmc_user, bmc_pass):
    """Check server PowerState via bmc-power.sh. Returns 'On', 'Off', or None."""
    cmd = ["./scripts/bmc-power.sh", "status", bmc_ip, bmc_user, bmc_pass]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        output = result.stdout.strip()
        if "Off" in output:
            return "Off"
        if "On" in output:
            return "On"
        return output if output else None
    except Exception as e:
        log(f"PowerState check failed: {e}")
        return None


def confirm_powerstate_off(bmc_ip, bmc_user, bmc_pass, context=""):
    """Double-check PowerState Off to avoid false positives."""
    log(f"PowerState Off detected ({context}), confirming in 10s...")
    time.sleep(10)
    state2 = check_powerstate(bmc_ip, bmc_user, bmc_pass)
    log(f"PowerState re-check: {state2}")
    if state2 == "Off":
        return True
    log(f"PowerState changed to {state2} - was transient Off, continuing")
    return False


def monitor_loop(child, log_file, timeout, powerstate_interval, bmc_ip, bmc_user, bmc_pass):
    """Main monitoring loop. Returns exit code."""
    start = time.time()
    last_powerstate_check = start
    current_stage_idx = -1
    power_down_detected = False

    log(f"Monitoring started (timeout={timeout}s, powerstate_interval={powerstate_interval}s)")

    while True:
        elapsed = time.time() - start
        if elapsed >= timeout:
            log(f"Timeout reached ({timeout}s)")
            return 1

        try:
            idx = child.expect([pexpect.TIMEOUT, pexpect.EOF], timeout=5)
        except (pexpect.TIMEOUT, pexpect.EOF):
            idx = 0

        new_data = child.before or ""
        if new_data and log_file:
            try:
                with open(log_file, "a", encoding="latin-1") as f:
                    f.write(new_data)
            except Exception as e:
                log(f"Log write error: {e}")

        if new_data:
            for i, (keyword, stage_name) in enumerate(INSTALLER_STAGES):
                if i > current_stage_idx and keyword in new_data:
                    current_stage_idx = i
                    elapsed_min = elapsed / 60
                    log(f"Stage: {stage_name} ({elapsed_min:.1f}min)")

            if not power_down_detected and "Power down" in new_data:
                power_down_detected = True
                log("Power down detected, waiting 30s for shutdown...")
                time.sleep(30)
                state = check_powerstate(bmc_ip, bmc_user, bmc_pass)
                log(f"PowerState after shutdown wait: {state}")
                if state == "Off":
                    log("Installation completed successfully (PowerState Off)")
                    return 0
                log("PowerState not Off yet, continuing monitoring...")

        if idx == 1:  # EOF
            log("SOL connection lost (EOF)")
            state = check_powerstate(bmc_ip, bmc_user, bmc_pass)
            if state == "Off":
                if confirm_powerstate_off(bmc_ip, bmc_user, bmc_pass, "SOL EOF"):
                    log("Installation completed (PowerState Off confirmed after SOL EOF)")
                    return 0
                log("Transient Off after SOL EOF, treating as abnormal termination")
            return 3

        now = time.time()
        if now - last_powerstate_check >= powerstate_interval:
            last_powerstate_check = now
            state = check_powerstate(bmc_ip, bmc_user, bmc_pass)
            elapsed_min = (now - start) / 60
            log(f"PowerState poll: {state} ({elapsed_min:.1f}min)")
            if state == "Off":
                if confirm_powerstate_off(bmc_ip, bmc_user, bmc_pass, "periodic poll"):
                    log("Installation completed (PowerState Off confirmed)")
                    return 0


def sol_connect_with_handshake(bmc_ip, bmc_user, bmc_pass):
    """Connect SOL and wait for initial handshake. Returns (child, True) or (None, False)."""
    try:
        child = sol_connect(bmc_ip, bmc_user, bmc_pass)
    except Exception as e:
        log(f"SOL connection failed: {e}")
        return None, False

    try:
        idx = child.expect(
            [pexpect.TIMEOUT, pexpect.EOF, "SOL session", "\\[SOL"],
            timeout=15,
        )
        if idx == 1:
            log("SOL connection failed (EOF immediately)")
            return None, False
    except pexpect.TIMEOUT:
        pass
    except pexpect.EOF:
        log("SOL connection failed (EOF)")
        return None, False

    return child, True


def main():
    parser = argparse.ArgumentParser(
        description="Passive SOL monitor for Debian installer progress"
    )
    parser.add_argument("--bmc-ip", required=True, help="BMC IP address")
    parser.add_argument("--bmc-user", required=True, help="BMC username")
    parser.add_argument("--bmc-pass", required=True, help="BMC password")
    parser.add_argument("--log-file", help="Path to save raw SOL output")
    parser.add_argument("--timeout", type=int, default=2700,
                        help="Max wait time in seconds (default: 2700 = 45min)")
    parser.add_argument("--powerstate-interval", type=int, default=20,
                        help="PowerState poll interval in seconds (default: 20)")
    parser.add_argument("--max-reconnects", type=int, default=3,
                        help="Max SOL reconnect attempts on EOF (default: 3)")
    args = parser.parse_args()

    child = None

    def cleanup(signum=None, frame=None):
        log("Signal received, cleaning up...")
        if child:
            disconnect_sol(child)
        sys.exit(3)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    if args.log_file:
        log_dir = os.path.dirname(args.log_file)
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
        with open(args.log_file, "w") as f:
            pass

    log("Deactivating any existing SOL session")
    deactivate_sol(args.bmc_ip, args.bmc_user, args.bmc_pass)
    time.sleep(2)

    global_start = time.time()
    reconnects = 0

    while reconnects <= args.max_reconnects:
        remaining = args.timeout - (time.time() - global_start)
        if remaining <= 0:
            log("Global timeout reached")
            sys.exit(1)

        if reconnects == 0:
            log(f"Connecting SOL to {args.bmc_ip}")
        else:
            log(f"Reconnecting SOL (attempt {reconnects}/{args.max_reconnects})")

        child, ok = sol_connect_with_handshake(
            args.bmc_ip, args.bmc_user, args.bmc_pass
        )
        if not ok:
            if reconnects == 0:
                sys.exit(2)
            reconnects += 1
            if reconnects > args.max_reconnects:
                break
            time.sleep(5)
            continue

        log("SOL connected, starting installer monitoring")
        rc = monitor_loop(
            child, args.log_file, remaining, args.powerstate_interval,
            args.bmc_ip, args.bmc_user, args.bmc_pass,
        )

        disconnect_sol(child)
        child = None

        if rc in (0, 1):
            sys.exit(rc)

        if rc == 3:  # EOF / abnormal
            state = check_powerstate(args.bmc_ip, args.bmc_user, args.bmc_pass)
            log(f"SOL lost, PowerState: {state}")
            if state == "Off":
                if confirm_powerstate_off(
                    args.bmc_ip, args.bmc_user, args.bmc_pass, "reconnect check"
                ):
                    log("Installation completed (PowerState Off after SOL loss)")
                    sys.exit(0)

            reconnects += 1
            if reconnects > args.max_reconnects:
                break

            log("Deactivating SOL before reconnect")
            deactivate_sol(args.bmc_ip, args.bmc_user, args.bmc_pass)
            time.sleep(5)
            continue

        # rc == 2 (connection error)
        sys.exit(rc)

    log(f"Max reconnects ({args.max_reconnects}) exceeded")
    sys.exit(3)


if __name__ == "__main__":
    main()
