#!/usr/bin/env python3
"""Extract a named file from a specific stream (1-indexed) of a concatenated
cpio archive (initramfs newc format)."""
import sys


def find_stream_offsets(data):
    offset = 0
    offsets = []
    while offset < len(data):
        while offset < len(data) and data[offset:offset+1] == b'\x00':
            offset += 1
        if offset >= len(data):
            break
        if data[offset:offset+6] != b'070701':
            break
        offsets.append(offset)
        # Walk to end of current stream (TRAILER!!! entry)
        while offset < len(data):
            if data[offset:offset+6] != b'070701':
                break
            namesize = int(data[offset+94:offset+102], 16)
            filesize = int(data[offset+54:offset+62], 16)
            name_start = offset + 110
            name_end = name_start + namesize
            name = data[name_start:name_end-1].decode('utf-8', errors='replace')
            pad1 = (4 - (name_end % 4)) % 4
            data_start = name_end + pad1
            data_end = data_start + filesize
            pad2 = (4 - (data_end % 4)) % 4
            offset = data_end + pad2
            if name == 'TRAILER!!!':
                break
    return offsets


def extract_file(data, start_offset, target_name):
    offset = start_offset
    while offset < len(data):
        if data[offset:offset+6] != b'070701':
            return None
        namesize = int(data[offset+94:offset+102], 16)
        filesize = int(data[offset+54:offset+62], 16)
        name_start = offset + 110
        name_end = name_start + namesize
        name = data[name_start:name_end-1].decode('utf-8', errors='replace')
        pad1 = (4 - (name_end % 4)) % 4
        data_start = name_end + pad1
        data_end = data_start + filesize
        pad2 = (4 - (data_end % 4)) % 4
        if name == target_name:
            return data[data_start:data_end]
        if name == 'TRAILER!!!':
            return None
        offset = data_end + pad2
    return None


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: extract-cpio-file.py <cpio> <stream-1indexed> <name>\n")
        sys.exit(2)
    archive_path = sys.argv[1]
    stream_num = int(sys.argv[2])
    target_name = sys.argv[3]
    with open(archive_path, 'rb') as f:
        data = f.read()
    offsets = find_stream_offsets(data)
    if stream_num < 1 or stream_num > len(offsets):
        sys.stderr.write(f"ERROR: stream {stream_num} not present (found {len(offsets)} streams)\n")
        sys.exit(1)
    content = extract_file(data, offsets[stream_num-1], target_name)
    if content is None:
        sys.stderr.write(f"ERROR: '{target_name}' not found in stream {stream_num}\n")
        sys.exit(1)
    sys.stdout.buffer.write(content)


if __name__ == '__main__':
    main()
