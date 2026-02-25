#!/usr/bin/env python3
"""SX6036 InfiniBand switch serial console CLI.

Connects to a Mellanox SX6036 switch via USB serial (/dev/ttyUSB0)
and executes MLNX-OS commands. Designed to run on the host server
(server 4) where the serial cable is physically connected.

Exit codes:
  0 - success
  1 - login failure
  2 - command execution failure
  3 - serial port connection error
"""
import argparse
import re
import serial
import sys
import time


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def strip_ansi(s):
    s = re.sub(r'\x1b\[[^a-zA-Z]*[a-zA-Z]', '', s)
    s = re.sub(r'\[\??\d+[hlK=><]', '', s)
    return s


def serial_open(device, baudrate):
    try:
        ser = serial.Serial(
            port=device, baudrate=baudrate,
            bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            xonxoff=False, rtscts=False, timeout=5,
        )
        log(f"Port opened: {ser.name}")
        return ser
    except serial.SerialException as e:
        log(f"Serial port error: {e}")
        sys.exit(3)


def read_until_prompt(ser, timeout, prompts=None):
    if prompts is None:
        prompts = ["> ", "# "]
    data = b""
    start = time.time()
    ser.timeout = 2
    while time.time() - start < timeout:
        chunk = ser.read(4096)
        if chunk:
            data += chunk
            decoded = data.decode("latin-1", errors="replace")
            if "--More--" in decoded or "--more--" in decoded:
                ser.write(b" ")
                ser.flush()
                data = data.replace(b"--More--", b"").replace(b"--more--", b"")
                continue
            lines = decoded.rstrip().split("\n")
            last = lines[-1].strip() if lines else ""
            for p in prompts:
                if last.endswith(p.strip()):
                    return strip_ansi(decoded)
    return strip_ansi(data.decode("latin-1", errors="replace"))


def login(ser, user, password):
    ser.reset_input_buffer()
    ser.reset_output_buffer()
    time.sleep(0.5)

    ser.write(b"\r")
    ser.flush()
    time.sleep(2)

    initial = ser.read(4096)
    decoded = initial.decode("latin-1", errors="replace") if initial else ""

    if ">" in decoded or "# " in decoded:
        log("Already logged in (prompt detected)")
        return True

    if "login:" in decoded.lower():
        log("Login prompt detected, sending credentials")
        ser.write(f"{user}\r".encode())
        ser.flush()
        time.sleep(2)
        ser.read(4096)

        ser.write(f"{password}\r".encode())
        ser.flush()
        time.sleep(5)
        data = read_until_prompt(ser, timeout=10)
        if ">" in data or "#" in data:
            log("Login successful")
            return True
        log(f"Login failed: {repr(data[:200])}")
        return False

    log("No prompt detected, sending credentials blind")
    ser.write(f"{user}\r".encode())
    ser.flush()
    time.sleep(2)
    ser.read(4096)

    ser.write(f"{password}\r".encode())
    ser.flush()
    time.sleep(5)
    data = read_until_prompt(ser, timeout=10)
    if ">" in data or "#" in data:
        log("Login successful")
        return True
    log(f"Login failed: {repr(data[:200])}")
    return False


def logout(ser):
    try:
        ser.write(b"exit\r")
        ser.flush()
        time.sleep(1)
    except Exception:
        pass
    try:
        ser.close()
    except Exception:
        pass
    log("Logged out")


def run_cmd(ser, cmd, timeout=30):
    ser.reset_input_buffer()
    ser.write(f"{cmd}\r".encode())
    ser.flush()
    time.sleep(0.5)
    output = read_until_prompt(ser, timeout)
    lines = output.split("\n")
    if lines and cmd in lines[0]:
        lines = lines[1:]
    if lines and (lines[-1].strip().endswith(">") or lines[-1].strip().endswith("#")):
        lines = lines[:-1]
    return "\n".join(lines)


def enter_enable(ser, password):
    log("Entering enable mode")
    ser.reset_input_buffer()
    ser.write(b"enable\r")
    ser.flush()
    time.sleep(2)

    data = ser.read(4096)
    decoded = data.decode("latin-1", errors="replace") if data else ""

    if "Password:" in decoded or "password:" in decoded:
        log("Enable password prompt detected")
        ser.write(f"{password}\r".encode())
        ser.flush()
        time.sleep(2)
        result = read_until_prompt(ser, timeout=10, prompts=["# "])
        if "#" in result:
            log("Enable mode activated")
            return True
        log(f"Enable mode failed: {repr(result[:200])}")
        return False

    if "#" in decoded:
        log("Enable mode activated (no password required)")
        return True

    result = read_until_prompt(ser, timeout=5, prompts=["# "])
    if "#" in result:
        log("Enable mode activated")
        return True
    log(f"Enable mode failed: {repr(decoded[:200])}")
    return False


def exit_enable(ser):
    ser.write(b"disable\r")
    ser.flush()
    time.sleep(1)
    read_until_prompt(ser, timeout=5)
    log("Exited enable mode")


def cmd_status(ser, args):
    sections = [
        ("Version", "show version"),
        ("Fan", "show fan"),
        ("Temperature", "show temperature"),
        ("Power", "show power"),
        ("Protocols", "show protocols"),
    ]
    for title, cmd in sections:
        log(f"Running: {cmd}")
        output = run_cmd(ser, cmd, timeout=args.timeout)
        print(f"\n{'='*60}")
        print(f"  {title}")
        print(f"{'='*60}")
        print(output)


def cmd_show(ser, args):
    cmd = "show " + " ".join(args.command)
    log(f"Running: {cmd}")
    output = run_cmd(ser, cmd, timeout=args.timeout)
    print(output)


def cmd_ports(ser, args):
    log("Running: show interfaces ib 1")
    output = run_cmd(ser, "show interfaces ib 1", timeout=args.timeout)
    print(output)


def cmd_enable_cmd(ser, args):
    if not enter_enable(ser, args.enable_pass):
        log("Failed to enter enable mode")
        sys.exit(2)
    cmd = " ".join(args.command)
    log(f"Running (enable): {cmd}")
    output = run_cmd(ser, cmd, timeout=args.timeout)
    print(output)
    exit_enable(ser)


def cmd_configure(ser, args):
    if not enter_enable(ser, args.enable_pass):
        log("Failed to enter enable mode")
        sys.exit(2)

    log("Entering configure terminal")
    ser.reset_input_buffer()
    ser.write(b"configure terminal\r")
    ser.flush()
    time.sleep(2)
    read_until_prompt(ser, timeout=10, prompts=["(config) #", "# "])

    with open(args.file, "r") as f:
        commands = [line.strip() for line in f if line.strip() and not line.startswith("#")]

    for cmd in commands:
        log(f"Configure: {cmd}")
        ser.reset_input_buffer()
        ser.write(f"{cmd}\r".encode())
        ser.flush()
        time.sleep(1)
        output = read_until_prompt(ser, timeout=args.timeout, prompts=["(config) #", "# "])
        print(f"> {cmd}")
        print(output)

    log("Exiting configure terminal")
    ser.write(b"exit\r")
    ser.flush()
    time.sleep(1)
    read_until_prompt(ser, timeout=5, prompts=["# "])

    exit_enable(ser)


def main():
    parser = argparse.ArgumentParser(
        description="SX6036 InfiniBand switch serial console CLI"
    )
    parser.add_argument("--device", default="/dev/ttyUSB0")
    parser.add_argument("--baudrate", type=int, default=9600)
    parser.add_argument("--user", default="admin")
    parser.add_argument("--pass", dest="password", default="admin")
    parser.add_argument("--enable-pass", default="admin")
    parser.add_argument("--timeout", type=int, default=30)

    sub = parser.add_subparsers(dest="subcommand", required=True)

    sub.add_parser("status", help="Show version, fan, temp, power, protocols")

    p_show = sub.add_parser("show", help="Run arbitrary show command")
    p_show.add_argument("command", nargs="+")

    sub.add_parser("ports", help="Show IB port status summary")

    p_enable = sub.add_parser("enable-cmd", help="Run command in enable mode")
    p_enable.add_argument("command", nargs="+")

    p_configure = sub.add_parser("configure", help="Run config commands from file")
    p_configure.add_argument("file", help="File with one command per line")

    args = parser.parse_args()

    ser = serial_open(args.device, args.baudrate)

    if not login(ser, args.user, args.password):
        ser.close()
        sys.exit(1)

    log("Disabling pager")
    run_cmd(ser, "no cli session paging enable", timeout=5)
    time.sleep(0.5)

    try:
        if args.subcommand == "status":
            cmd_status(ser, args)
        elif args.subcommand == "show":
            cmd_show(ser, args)
        elif args.subcommand == "ports":
            cmd_ports(ser, args)
        elif args.subcommand == "enable-cmd":
            cmd_enable_cmd(ser, args)
        elif args.subcommand == "configure":
            cmd_configure(ser, args)
    except Exception as e:
        log(f"Error: {e}")
        logout(ser)
        sys.exit(2)

    logout(ser)


if __name__ == "__main__":
    main()
