#!/usr/bin/env python3
"""Send `c` + GRUB shell commands over ipmitool SOL using pexpect.

Workflow:
  1. spawn ipmitool sol activate (waits for SOL_OK)
  2. send 'c' (GRUB menu → command line entry)
  3. wait 2s
  4. send "ls (cd0)/install.amd/vmlinuz\n"
  5. wait 5s
  6. send "ls (cd0)/install.amd/initrd.gz\n"
  7. wait 5s
  8. send "cat (cd0)/install.amd/vmlinuz\n"
  9. wait 60s (binary flood + Ctrl+C does not work over SOL → just observe)
 10. capture full output to tmp/phase6a01/grub-sol-output.log
 11. ipmitool tilde-dot deactivate
"""
import sys
import time
import os
import pexpect

BMC_IP = "10.254.254.9"
BMC_USER = "claude"
BMC_PASS = "Claude123"
LOG = "/home/ubuntu/projects/pvese/tmp/phase6a01/grub-sol-output.log"

cmd = f"ipmitool -I lanplus -H {BMC_IP} -U {BMC_USER} -P {BMC_PASS} sol activate"

with open(LOG, "wb") as fp:
    child = pexpect.spawn(cmd, timeout=30, logfile=fp)
    try:
        child.expect("Use ~.", timeout=20)
        print("SOL session established", file=sys.stderr)

        # Pause briefly to let SOL ring-buffer drain
        time.sleep(2)
        fp.write(b"\n\n--- SENDING 'c' (GRUB command-line entry) ---\n")
        fp.flush()

        # Send 'c' to enter GRUB command line
        child.send("c")
        time.sleep(3)

        fp.write(b"\n\n--- SENDING ls (cd0)/install.amd/vmlinuz ---\n")
        fp.flush()
        child.send("ls (cd0)/install.amd/vmlinuz\r")
        time.sleep(5)

        fp.write(b"\n\n--- SENDING ls (cd0)/install.amd/initrd.gz ---\n")
        fp.flush()
        child.send("ls (cd0)/install.amd/initrd.gz\r")
        time.sleep(5)

        fp.write(b"\n\n--- SENDING ls (single, device list) ---\n")
        fp.flush()
        child.send("ls\r")
        time.sleep(5)

        fp.write(b"\n\n--- SENDING cat (cd0)/install.amd/vmlinuz (60s observation) ---\n")
        fp.flush()
        child.send("cat (cd0)/install.amd/vmlinuz\r")

        # Read for 60 sec while binary data floods
        end = time.time() + 60
        while time.time() < end:
            try:
                child.read_nonblocking(size=4096, timeout=1)
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                break

        fp.write(b"\n\n--- DONE; sending ESC + ~. to deactivate ---\n")
        fp.flush()
        # GRUB Ctrl+C / ESC cannot be sent cleanly over SOL; just close
        child.sendline()
        child.send("~.")
        time.sleep(2)
        child.close(force=True)
    finally:
        if child.isalive():
            child.close(force=True)

print(f"Log saved to {LOG}", file=sys.stderr)
