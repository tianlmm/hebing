#!/usr/bin/env python3
"""Helper: extract members from a traditional ar-archive .ipk into a directory.

Usage: python3 _extract_ar_ipk.py in.ipk out_dir
Produces out_dir/debian-binary, out_dir/control.tar.gz, out_dir/data.tar.gz
"""
import os, sys

def extract_ar_ipk(in_path, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    with open(in_path, "rb") as f:
        magic = f.read(8)
        assert magic == b"!<arch>\n", f"bad ar magic: {magic!r}"
        f.seek(8)
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            name = hdr[0:16].split(b"\x00", 1)[0].decode(errors="replace")
            try:
                size = int(hdr[48:58].decode().strip())
            except ValueError:
                break
            body = f.read(size)
            if size % 2 == 1:
                f.read(1)  # padding
            out = os.path.join(out_dir, name)
            with open(out, "wb") as w:
                w.write(body)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} in.ipk out_dir", file=sys.stderr)
        sys.exit(2)
    extract_ar_ipk(sys.argv[1], sys.argv[2])
