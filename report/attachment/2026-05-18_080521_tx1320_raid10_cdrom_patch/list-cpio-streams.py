#!/usr/bin/env python3
"""List entries from all cpio streams concatenated in a binary file.

cpio newc format: each entry header starts with "070701" magic, contains
a fixed-format ASCII header (110 bytes total), then padded name and data.
The archive ends with an entry named "TRAILER!!!". If multiple cpio
archives are concatenated (initramfs supports this), there will be
multiple TRAILER!!! entries.
"""
import sys

def read_newc(data, offset):
    # 110-byte header: "070701" + 13 fields of 8 hex digits each
    if offset >= len(data):
        return None
    if data[offset:offset+6] != b'070701':
        return None
    hdr = data[offset:offset+110]
    namesize = int(hdr[94:102], 16)
    filesize = int(hdr[54:62], 16)
    name_start = offset + 110
    name_end = name_start + namesize
    name = data[name_start:name_end-1].decode('utf-8', errors='replace')  # strip NUL
    # Header+name padded to multiple of 4
    after_name = name_end
    pad1 = (4 - (after_name % 4)) % 4
    data_start = after_name + pad1
    data_end = data_start + filesize
    pad2 = (4 - (data_end % 4)) % 4
    next_offset = data_end + pad2
    return (name, filesize, next_offset)

def main(path):
    with open(path, 'rb') as f:
        data = f.read()
    offset = 0
    stream = 0
    entries = []
    while offset < len(data):
        # Skip padding zeros between cpio streams
        while offset < len(data) and data[offset:offset+1] == b'\x00':
            offset += 1
        if offset >= len(data):
            break
        if data[offset:offset+6] != b'070701':
            print(f"WARN: non-cpio data at offset {offset}", file=sys.stderr)
            break
        stream += 1
        print(f"=== Stream #{stream} starting at offset {offset} ===")
        while offset < len(data):
            result = read_newc(data, offset)
            if result is None:
                break
            name, size, next_offset = result
            entries.append((stream, name, size))
            offset = next_offset
            if name == 'TRAILER!!!':
                print(f"  (TRAILER at end of stream #{stream})")
                break
        # entries this stream
    # Show summary of stream 2 entries (the inject)
    print("\n=== Stream contents summary ===")
    for s, n, sz in entries:
        if s >= 2:
            print(f"stream={s} size={sz:>8} name={n}")
    # Counts
    s1_count = sum(1 for s, _, _ in entries if s == 1)
    s2_count = sum(1 for s, _, _ in entries if s == 2)
    print(f"\nStream 1 entries: {s1_count}")
    print(f"Stream 2 entries: {s2_count}")
    print(f"Total streams: {stream}")

if __name__ == '__main__':
    main(sys.argv[1])
