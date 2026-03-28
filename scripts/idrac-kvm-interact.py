#!/usr/bin/env python3
"""iDRAC7 KVM interactive control via VNC (RFB 3.008).

Send keystrokes and capture screenshots through direct VNC connection.
No browser or Playwright needed — pure socket-based RFB protocol.

Commands:
  screenshot <output.png>              Capture KVM screenshot
  sendkeys <key1> [key2] ...           Send keyboard keys
  type <text>                          Type text string

Options for sendkeys/type:
  --wait MS              Wait MS milliseconds after each key (default: 100)
  --screenshot FILE      Capture screenshot after sending keys
  --post-wait MS         Wait MS milliseconds before screenshot (default: 500)
  --screenshot-each PFX  Capture after each key: PFX_001.png, PFX_002.png, ...
  --pre-screenshot       Also capture initial state as PFX_000.png

Key names:
  Letters/digits: a-z, 0-9
  Special: Enter, Escape, Tab, Backspace, Delete, Space
  Navigation: ArrowUp, ArrowDown, ArrowLeft, ArrowRight
  Function: F1-F12
  Modifiers: Shift, Control, Alt
  Combos: Ctrl+r (hold modifier, press key, release both)
  Repeat: Delete x60 (send Delete 60 times)

Exit codes:
  0 = success
  1 = connection/auth failure
  2 = timeout or capture failure
"""
import argparse
import os
import socket
import struct
import sys
import time

try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
except ImportError:
    print("ERROR: cryptography not installed", file=sys.stderr)
    sys.exit(3)

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow not installed", file=sys.stderr)
    sys.exit(3)


# X11 keysym mapping for RFB KeyEvent
X11_KEYSYMS = {
    "Escape": 0xFF1B, "Tab": 0xFF09, "Backspace": 0xFF08,
    "Enter": 0xFF0D, "Return": 0xFF0D, "Delete": 0xFFFF,
    "Home": 0xFF50, "End": 0xFF57,
    "PageUp": 0xFF55, "PageDown": 0xFF56,
    "ArrowUp": 0xFF52, "ArrowDown": 0xFF54,
    "ArrowLeft": 0xFF51, "ArrowRight": 0xFF53,
    "F1": 0xFFBE, "F2": 0xFFBF, "F3": 0xFFC0, "F4": 0xFFC1,
    "F5": 0xFFC2, "F6": 0xFFC3, "F7": 0xFFC4, "F8": 0xFFC5,
    "F9": 0xFFC6, "F10": 0xFFC7, "F11": 0xFFC8, "F12": 0xFFC9,
    "Shift": 0xFFE1, "Control": 0xFFE3, "Alt": 0xFFE9,
    "Space": 0x0020, "+": 0x002B, "-": 0x002D,
}


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


def vnc_des_encrypt(password, challenge):
    """VNC DES auth with bit-reversed key."""
    key = bytearray(8)
    pw = password.encode("ascii")[:8]
    for i in range(len(pw)):
        key[i] = int("{:08b}".format(pw[i])[::-1], 2)
    cipher = Cipher(algorithms.TripleDES(bytes(key) * 3), modes.ECB())
    enc = cipher.encryptor()
    return enc.update(challenge[:8]) + enc.update(challenge[8:16]) + enc.finalize()


def recv_exact(sock, n):
    """Receive exactly n bytes."""
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError(f"Connection closed ({len(data)}/{n})")
        data.extend(chunk)
    return bytes(data)


class VNCSession:
    """Persistent VNC session for screenshot + keyboard interaction."""

    def __init__(self, host, port, password, timeout):
        self.host = host
        self.port = port
        self.password = password
        self.timeout = timeout
        self.sock = None
        self.width = 0
        self.height = 0
        self.bpp = 0
        self.bytes_per_pixel = 0
        self.r_max = self.g_max = self.b_max = 0
        self.r_shift = self.g_shift = self.b_shift = 0

    def connect(self):
        """Connect and authenticate."""
        self.sock = socket.create_connection(
            (self.host, self.port), timeout=self.timeout)
        self.sock.settimeout(self.timeout)

        # RFB handshake
        ver = self.sock.recv(12)
        if not ver.startswith(b"RFB"):
            raise ConnectionError(f"Not VNC: {ver!r}")
        self.sock.sendall(b"RFB 003.008\n")

        # Security
        num = struct.unpack("!B", recv_exact(self.sock, 1))[0]
        if num == 0:
            rlen = struct.unpack("!I", recv_exact(self.sock, 4))[0]
            reason = recv_exact(self.sock, rlen).decode("utf-8", errors="replace")
            raise ConnectionError(f"Refused: {reason}")

        types = list(recv_exact(self.sock, num))
        if 2 not in types:
            raise ConnectionError(f"No VNC auth (types={types})")

        self.sock.sendall(bytes([2]))
        challenge = recv_exact(self.sock, 16)
        self.sock.sendall(vnc_des_encrypt(self.password, challenge))

        result = struct.unpack("!I", recv_exact(self.sock, 4))[0]
        if result != 0:
            raise ConnectionError(f"Auth failed ({result})")

        # ClientInit shared=1
        self.sock.sendall(bytes([1]))

        # ServerInit
        si = recv_exact(self.sock, 4)
        self.width, self.height = struct.unpack("!HH", si)
        pf = recv_exact(self.sock, 16)
        self.bpp = pf[0]
        self.bytes_per_pixel = self.bpp // 8
        self.r_max, self.g_max, self.b_max = struct.unpack("!HHH", pf[4:10])
        self.r_shift, self.g_shift, self.b_shift = pf[10], pf[11], pf[12]

        name_len = struct.unpack("!I", recv_exact(self.sock, 4))[0]
        recv_exact(self.sock, name_len)

        # Set encodings: Raw only
        msg = struct.pack("!BxH", 2, 1) + struct.pack("!i", 0)
        self.sock.sendall(msg)

        log(f"Connected {self.width}x{self.height} {self.bpp}bpp")

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def send_key(self, keysym, down=True):
        """Send RFB KeyEvent."""
        self.sock.sendall(struct.pack("!BBxxI", 4, 1 if down else 0, keysym))

    def press_key(self, keysym):
        """Press and release a key."""
        self.send_key(keysym, True)
        self.send_key(keysym, False)

    def send_named_key(self, name):
        """Send a key by name (e.g. 'Enter', 'ArrowUp', 'a', 'Ctrl+r')."""
        if "+" in name and len(name) > 1 and name not in ("+",):
            parts = name.split("+")
            modifier_names = parts[:-1]
            key_name = parts[-1]
            modifiers = []
            for m in modifier_names:
                m_canon = m.capitalize()
                if m_canon == "Ctrl":
                    m_canon = "Control"
                sym = X11_KEYSYMS.get(m_canon)
                if sym is None:
                    log(f"Unknown modifier: {m}")
                    return
                modifiers.append(sym)
            key_sym = self._resolve_keysym(key_name)
            if key_sym is None:
                return
            for m in modifiers:
                self.send_key(m, True)
            self.press_key(key_sym)
            for m in reversed(modifiers):
                self.send_key(m, False)
        else:
            sym = self._resolve_keysym(name)
            if sym is not None:
                self.press_key(sym)

    def _resolve_keysym(self, name):
        """Resolve key name to X11 keysym."""
        if name in X11_KEYSYMS:
            return X11_KEYSYMS[name]
        if len(name) == 1:
            return ord(name)
        log(f"Unknown key: {name}")
        return None

    def _drain_messages(self, timeout_sec=0.5):
        """Drain pending server messages (non-blocking)."""
        self.sock.settimeout(timeout_sec)
        try:
            while True:
                b = self.sock.recv(4096)
                if not b:
                    break
        except socket.timeout:
            pass
        self.sock.settimeout(self.timeout)

    def wake(self):
        """Send a harmless key to wake VNC from SYSTEM IDLE.

        iDRAC7 VNC stops video capture when idle. After wake, the server
        needs 2-3 seconds to restart video capture and produce a fresh frame.
        """
        self.send_key(0xFFE3, True)
        self.send_key(0xFFE3, False)
        time.sleep(3)

    def _capture_framebuffer(self, output):
        """Capture framebuffer once (internal, no wake)."""

        # Request full framebuffer update
        self.sock.sendall(struct.pack("!BBHHHH", 3, 0, 0, 0,
                                       self.width, self.height))

        framebuf = bytearray(self.width * self.height * 4)
        got_update = False
        self.sock.settimeout(self.timeout)

        while True:
            msg_type = struct.unpack("!B", recv_exact(self.sock, 1))[0]

            if msg_type == 0:  # FramebufferUpdate
                recv_exact(self.sock, 1)
                num_rects = struct.unpack("!H", recv_exact(self.sock, 2))[0]

                for _ in range(num_rects):
                    hdr = recv_exact(self.sock, 12)
                    rx, ry, rw, rh, enc = struct.unpack("!HHHHi", hdr)

                    if enc == 0:  # Raw
                        data = recv_exact(self.sock, rw * rh * self.bytes_per_pixel)
                        for row in range(rh):
                            src = row * rw * self.bytes_per_pixel
                            dst = ((ry + row) * self.width + rx) * 4
                            if self.bytes_per_pixel == 4:
                                framebuf[dst:dst + rw * 4] = data[src:src + rw * 4]
                            elif self.bytes_per_pixel == 2:
                                for px in range(rw):
                                    val = struct.unpack_from(
                                        "<H", data, src + px * 2)[0]
                                    r = ((val >> self.r_shift) & self.r_max) * 255 // max(self.r_max, 1)
                                    g = ((val >> self.g_shift) & self.g_max) * 255 // max(self.g_max, 1)
                                    b = ((val >> self.b_shift) & self.b_max) * 255 // max(self.b_max, 1)
                                    framebuf[dst + px * 4] = r
                                    framebuf[dst + px * 4 + 1] = g
                                    framebuf[dst + px * 4 + 2] = b
                                    framebuf[dst + px * 4 + 3] = 255
                    else:
                        log(f"Unsupported encoding {enc}")
                        return False

                got_update = True
                break

            elif msg_type == 1:  # SetColourMapEntries
                recv_exact(self.sock, 1)
                recv_exact(self.sock, 2)
                nc = struct.unpack("!H", recv_exact(self.sock, 2))[0]
                recv_exact(self.sock, nc * 6)
            elif msg_type == 2:  # Bell
                pass
            elif msg_type == 3:  # ServerCutText
                recv_exact(self.sock, 3)
                tlen = struct.unpack("!I", recv_exact(self.sock, 4))[0]
                recv_exact(self.sock, tlen)
            else:
                log(f"Unknown msg {msg_type}")
                break

        if not got_update:
            return False

        img = Image.frombytes("RGBX", (self.width, self.height), bytes(framebuf))
        img = img.convert("RGB")
        outdir = os.path.dirname(output)
        if outdir:
            os.makedirs(outdir, exist_ok=True)
        img.save(output)
        return True

    def screenshot(self, output):
        """Wake from SYSTEM IDLE and capture screenshot.

        Takes two framebuffer captures: first may be stale SYSTEM IDLE,
        second should be the real screen content.
        """
        self.wake()
        self._capture_framebuffer(output)
        time.sleep(1)
        return self._capture_framebuffer(output)


def parse_keys(key_args):
    """Parse key arguments, expanding 'Key xN' repeat syntax."""
    keys = []
    i = 0
    while i < len(key_args):
        key = key_args[i]
        if (i + 1 < len(key_args) and key_args[i + 1].startswith("x")
                and key_args[i + 1][1:].isdigit()):
            count = int(key_args[i + 1][1:])
            keys.extend([key] * count)
            i += 2
        else:
            keys.append(key)
            i += 1
    return keys


def main():
    parser = argparse.ArgumentParser(
        description="iDRAC7 KVM interactive control via VNC")
    parser.add_argument("--bmc-ip", required=True, help="iDRAC IP")
    parser.add_argument("--vnc-port", type=int, default=5901, help="VNC port")
    parser.add_argument("--vnc-pass", default="Claude1", help="VNC password")
    parser.add_argument("--timeout", type=int, default=30, help="Timeout (sec)")

    sub = parser.add_subparsers(dest="command")

    # screenshot
    p_ss = sub.add_parser("screenshot", help="Capture screenshot")
    p_ss.add_argument("output", help="Output PNG path")

    # sendkeys
    p_sk = sub.add_parser("sendkeys", help="Send keyboard keys")
    p_sk.add_argument("keys", nargs="+", help="Key names (or Key xN)")
    p_sk.add_argument("--wait", type=int, default=100,
                      help="Wait ms after each key (default: 100)")
    p_sk.add_argument("--screenshot", dest="screenshot_file",
                      help="Screenshot after all keys")
    p_sk.add_argument("--post-wait", type=int, default=500,
                      help="Wait ms before final screenshot (default: 500)")
    p_sk.add_argument("--screenshot-each", dest="screenshot_prefix",
                      help="Screenshot after each key: PFX_001.png ...")
    p_sk.add_argument("--pre-screenshot", action="store_true",
                      help="Capture PFX_000.png before first key")

    # type
    p_ty = sub.add_parser("type", help="Type text string")
    p_ty.add_argument("text", help="Text to type")
    p_ty.add_argument("--wait", type=int, default=50,
                      help="Wait ms after each char (default: 50)")
    p_ty.add_argument("--screenshot", dest="screenshot_file",
                      help="Screenshot after typing")
    p_ty.add_argument("--post-wait", type=int, default=500,
                      help="Wait ms before screenshot (default: 500)")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    session = VNCSession(args.bmc_ip, args.vnc_port, args.vnc_pass, args.timeout)
    try:
        session.connect()

        if args.command == "screenshot":
            if session.screenshot(args.output):
                log(f"Saved {args.output}")
            else:
                log("Screenshot failed")
                sys.exit(2)

        elif args.command == "sendkeys":
            keys = parse_keys(args.keys)
            log(f"Sending {len(keys)} keys")

            if getattr(args, "pre_screenshot", False) and args.screenshot_prefix:
                fn = f"{args.screenshot_prefix}_000.png"
                session._capture_framebuffer(fn)
                log(f"Pre-screenshot: {fn}")

            for idx, key in enumerate(keys, 1):
                session.send_named_key(key)
                time.sleep(args.wait / 1000.0)

                if args.screenshot_prefix:
                    fn = f"{args.screenshot_prefix}_{idx:03d}.png"
                    time.sleep(args.post_wait / 1000.0)
                    session._capture_framebuffer(fn)

            if args.screenshot_file and not args.screenshot_prefix:
                time.sleep(args.post_wait / 1000.0)
                if session._capture_framebuffer(args.screenshot_file):
                    log(f"Saved {args.screenshot_file}")

        elif args.command == "type":
            log(f"Typing {len(args.text)} chars")
            for ch in args.text:
                session.press_key(ord(ch))
                time.sleep(args.wait / 1000.0)

            if args.screenshot_file:
                time.sleep(args.post_wait / 1000.0)
                if session.screenshot(args.screenshot_file):
                    log(f"Saved {args.screenshot_file}")

    except Exception as e:
        log(f"Error: {e}")
        sys.exit(1)
    finally:
        session.close()


if __name__ == "__main__":
    main()
