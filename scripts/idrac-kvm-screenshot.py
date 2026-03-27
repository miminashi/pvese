#!/usr/bin/env python3
"""iDRAC7 KVM screenshot capture.

Primary method: VNC direct connection (port 5901, RFB 3.008).
Fallback: capconsole API (400x300 grayscale thumbnail).

VNC is tried up to 3 times. If all attempts fail, falls back to capconsole.

Exit codes:
  0 = success
  1 = auth failure (both methods)
  2 = screenshot capture failure (both methods)
"""
import argparse
import os
import re
import socket
import ssl
import struct
import sys
import time
import http.cookiejar
import urllib.request
import urllib.parse

# Optional imports for VNC
try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False


def log(msg):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# VNC screenshot (primary method)
# ---------------------------------------------------------------------------

def vnc_des_encrypt(password, challenge):
    """VNC DES auth: encrypt 16-byte challenge with bit-reversed password key."""
    key = bytearray(8)
    pw = password.encode("ascii")[:8]
    for i in range(len(pw)):
        key[i] = int("{:08b}".format(pw[i])[::-1], 2)
    cipher = Cipher(algorithms.TripleDES(bytes(key) * 3), modes.ECB())
    enc = cipher.encryptor()
    return enc.update(challenge[:8]) + enc.update(challenge[8:16]) + enc.finalize()


def recv_exact(sock, n):
    """Receive exactly n bytes from socket."""
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError(f"Connection closed (got {len(data)}/{n} bytes)")
        data.extend(chunk)
    return bytes(data)


def vnc_screenshot(host, port, password, output, timeout):
    """Capture screenshot via VNC (RFB 3.008). Returns 0 on success, 2 on failure."""
    sock = None
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.settimeout(timeout)

        # RFB version handshake
        ver = sock.recv(12)
        if not ver.startswith(b"RFB"):
            log(f"VNC: Not a VNC server: {ver!r}")
            return 2
        sock.sendall(b"RFB 003.008\n")

        # Security types
        num_types = struct.unpack("!B", recv_exact(sock, 1))[0]
        if num_types == 0:
            reason_len = struct.unpack("!I", recv_exact(sock, 4))[0]
            reason = recv_exact(sock, reason_len).decode("utf-8", errors="replace")
            log(f"VNC: Refused: {reason}")
            return 2

        sec_types = list(recv_exact(sock, num_types))
        if 2 not in sec_types:
            log(f"VNC: No VNC auth (types: {sec_types})")
            return 2

        # VNC Auth (type 2)
        sock.sendall(bytes([2]))
        challenge = recv_exact(sock, 16)
        response = vnc_des_encrypt(password, challenge)
        sock.sendall(response)

        result = struct.unpack("!I", recv_exact(sock, 4))[0]
        if result != 0:
            log(f"VNC: Auth failed (result={result})")
            return 2

        # ClientInit (shared=1)
        sock.sendall(bytes([1]))

        # ServerInit
        si = recv_exact(sock, 4)
        width, height = struct.unpack("!HH", si)
        pf = recv_exact(sock, 16)
        bpp = pf[0]
        name_len = struct.unpack("!I", recv_exact(sock, 4))[0]
        recv_exact(sock, name_len)
        log(f"VNC: {width}x{height} {bpp}bpp")

        # Pixel format info
        r_max, g_max, b_max = struct.unpack("!HHH", pf[4:10])
        r_shift, g_shift, b_shift = pf[10], pf[11], pf[12]
        bytes_per_pixel = bpp // 8

        # Set encodings: Raw only
        msg = struct.pack("!BxH", 2, 1) + struct.pack("!i", 0)
        sock.sendall(msg)

        # Send wake key event (space key down + up) to exit SYSTEM IDLE
        sock.sendall(struct.pack("!BBxxI", 4, 1, 0x20))
        sock.sendall(struct.pack("!BBxxI", 4, 0, 0x20))
        time.sleep(0.5)

        # Request full framebuffer update
        sock.sendall(struct.pack("!BBHHHH", 3, 0, 0, 0, width, height))

        # Receive framebuffer
        framebuf = bytearray(width * height * 4)
        got_update = False

        while True:
            msg_type = struct.unpack("!B", recv_exact(sock, 1))[0]

            if msg_type == 0:  # FramebufferUpdate
                recv_exact(sock, 1)  # padding
                num_rects = struct.unpack("!H", recv_exact(sock, 2))[0]

                for _ in range(num_rects):
                    hdr = recv_exact(sock, 12)
                    rx, ry, rw, rh, enc = struct.unpack("!HHHHi", hdr)

                    if enc == 0:  # Raw
                        data = recv_exact(sock, rw * rh * bytes_per_pixel)
                        for row in range(rh):
                            src_off = row * rw * bytes_per_pixel
                            dst_off = ((ry + row) * width + rx) * 4
                            if bytes_per_pixel == 4:
                                framebuf[dst_off:dst_off + rw * 4] = \
                                    data[src_off:src_off + rw * 4]
                            elif bytes_per_pixel == 2:
                                for px in range(rw):
                                    val = struct.unpack_from(
                                        "<H", data, src_off + px * 2)[0]
                                    r = ((val >> r_shift) & r_max) * 255 // max(r_max, 1)
                                    g = ((val >> g_shift) & g_max) * 255 // max(g_max, 1)
                                    b = ((val >> b_shift) & b_max) * 255 // max(b_max, 1)
                                    framebuf[dst_off + px * 4] = r
                                    framebuf[dst_off + px * 4 + 1] = g
                                    framebuf[dst_off + px * 4 + 2] = b
                                    framebuf[dst_off + px * 4 + 3] = 255
                    else:
                        log(f"VNC: Unsupported encoding {enc}")
                        return 2

                got_update = True
                break

            elif msg_type == 1:  # SetColourMapEntries
                recv_exact(sock, 1)
                recv_exact(sock, 2)
                num_colours = struct.unpack("!H", recv_exact(sock, 2))[0]
                recv_exact(sock, num_colours * 6)
            elif msg_type == 2:  # Bell
                pass
            elif msg_type == 3:  # ServerCutText
                recv_exact(sock, 3)
                text_len = struct.unpack("!I", recv_exact(sock, 4))[0]
                recv_exact(sock, text_len)
            else:
                log(f"VNC: Unknown msg type {msg_type}")
                break

        if not got_update:
            log("VNC: No framebuffer update received")
            return 2

        # Save as PNG
        img = Image.frombytes("RGBX", (width, height), bytes(framebuf))
        img = img.convert("RGB")
        output_dir = os.path.dirname(output)
        if output_dir:
            os.makedirs(output_dir, exist_ok=True)
        img.save(output)
        log(f"VNC: Saved {output} ({width}x{height}, {os.path.getsize(output)} bytes)")
        return 0

    except Exception as e:
        log(f"VNC: {e}")
        return 2
    finally:
        if sock:
            try:
                sock.close()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# capconsole API screenshot (fallback)
# ---------------------------------------------------------------------------

def make_ssl_context():
    """Create SSL context that ignores cert errors."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def idrac_login(ssl_ctx, bmc_ip, user, password, timeout):
    """Login to iDRAC7 and return (session_cookie, st2_token) tuple."""
    url = f"https://{bmc_ip}/data/login"
    data = urllib.parse.urlencode({"user": user, "password": password}).encode()

    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(cj),
        urllib.request.HTTPSHandler(context=ssl_ctx),
    )

    try:
        resp = opener.open(url, data, timeout=timeout)
        body = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        log(f"capconsole: Login failed: {e}")
        return None, None

    auth_match = re.search(r"<authResult>(\d+)</authResult>", body)
    if not auth_match or auth_match.group(1) != "0":
        auth_val = auth_match.group(1) if auth_match else "not found"
        log(f"capconsole: Auth failed (authResult={auth_val})")
        return None, None

    session_cookie = None
    for c in cj:
        session_cookie = f"{c.name}={c.value}"
        break

    st2_match = re.search(r"ST2=([^<\"&\s,]+)", body)
    if not st2_match:
        log("capconsole: ST2 token not found")
        return None, None

    log(f"capconsole: Login OK (ST2: {st2_match.group(1)[:8]}...)")
    return session_cookie, st2_match.group(1)


def idrac_capconsole(ssl_ctx, bmc_ip, session_cookie, st2, output, timeout):
    """Capture screenshot via capconsole API. Returns 0 on success, 2 on failure."""
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ssl_ctx),
    )

    ts = str(int(time.time() * 1000))
    preview_url = f"https://{bmc_ip}/data?get=consolepreview[auto%20{ts}]"
    req = urllib.request.Request(preview_url)
    req.add_header("Cookie", session_cookie)
    req.add_header("ST2", st2)

    try:
        resp = opener.open(req, timeout=timeout)
        resp.read()
    except Exception as e:
        log(f"capconsole: Preview trigger failed: {e}")

    time.sleep(1)

    ts2 = str(int(time.time() * 1000))
    png_url = f"https://{bmc_ip}/capconsole/scapture0.png?{ts2}"
    req = urllib.request.Request(png_url)
    req.add_header("Cookie", f"{session_cookie}; -ST2={st2}")

    try:
        resp = opener.open(req, timeout=timeout)
        png_data = resp.read()
    except urllib.error.HTTPError as e:
        log(f"capconsole: HTTP {e.code}")
        return 2
    except Exception as e:
        log(f"capconsole: {e}")
        return 2

    if len(png_data) < 100:
        log(f"capconsole: Too small ({len(png_data)} bytes)")
        return 2

    if png_data[:4] != b"\x89PNG":
        log("capconsole: Not a PNG image")
        return 2

    output_dir = os.path.dirname(output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    with open(output, "wb") as f:
        f.write(png_data)

    log(f"capconsole: Saved {output} ({len(png_data)} bytes, 400x300 grayscale)")
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="iDRAC7 KVM screenshot (VNC primary, capconsole fallback)"
    )
    parser.add_argument("--bmc-ip", required=True, help="iDRAC IP address")
    parser.add_argument("--bmc-user", required=True, help="iDRAC username")
    parser.add_argument("--bmc-pass", required=True, help="iDRAC password")
    parser.add_argument("--output", required=True, help="Output PNG file path")
    parser.add_argument(
        "--timeout", type=int, default=30, help="Timeout in seconds (default: 30)")
    parser.add_argument(
        "--vnc-pass", default="Claude1", help="VNC password (default: Claude1)")
    parser.add_argument(
        "--vnc-port", type=int, default=5901, help="VNC port (default: 5901)")
    args = parser.parse_args()

    vnc_timeout = max(args.timeout // 2, 10)

    # Primary: VNC (3 attempts)
    if HAS_CRYPTO and HAS_PIL:
        for attempt in range(1, 4):
            log(f"VNC: Attempt {attempt}/3 ({args.bmc_ip}:{args.vnc_port})")
            rc = vnc_screenshot(
                args.bmc_ip, args.vnc_port, args.vnc_pass,
                args.output, vnc_timeout)
            if rc == 0:
                sys.exit(0)
            if attempt < 3:
                time.sleep(2)
        log("VNC: All 3 attempts failed, falling back to capconsole API")
    else:
        missing = []
        if not HAS_CRYPTO:
            missing.append("cryptography")
        if not HAS_PIL:
            missing.append("Pillow")
        log(f"VNC: Skipped (missing: {', '.join(missing)})")

    # Fallback: capconsole API
    ssl_ctx = make_ssl_context()
    session_cookie, st2 = idrac_login(
        ssl_ctx, args.bmc_ip, args.bmc_user, args.bmc_pass, args.timeout)
    if st2 is None:
        sys.exit(1)

    rc = idrac_capconsole(
        ssl_ctx, args.bmc_ip, session_cookie, st2, args.output, args.timeout)
    sys.exit(rc)


if __name__ == "__main__":
    main()
