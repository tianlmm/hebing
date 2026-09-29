#!/usr/bin/env python3
"""Helper: build a traditional ar-archive .ipk for OpenWrt opkg compatibility.

ar format (per entry header, 60 bytes):
  name[16] mtime[12] uid[6] gid[6] mode[8] size[10] magic[2]   # magic = b'`\\n'
archive starts with global magic b'!<arch>\\n'  (8 bytes).
Member order must be: 1. debian-binary  2. control.tar.gz  3. data.tar.gz
Odd-sized members get a single padding byte (extra '\\n') after the payload.
"""
import os, sys

def build_ar_ipk(out_path, debian_binary, control_tar, data_tar):
    members = [
        ("debian-binary", open(debian_binary, "rb").read()),
        ("control.tar.gz",  open(control_tar,  "rb").read()),
        ("data.tar.gz",     open(data_tar,     "rb").read()),
    ]
    with open(out_path, "wb") as out:
        out.write(b"!<arch>\n")
        for name, body in members:
            assert len(name) <= 16, f"ar member name too long: {name}"
            hdr  = name.encode().ljust(16, b"\x00")  # name 16 bytes
            hdr += b"0".ljust(12, b" ")             # mtime 12 bytes
            hdr += b"0".ljust(6,  b" ")             # uid 6 bytes
            hdr += b"0".ljust(6,  b" ")             # gid 6 bytes
            hdr += b"100644".ljust(8, b" ")         # mode 8 bytes
            hdr += f"{len(body)}".encode().ljust(10, b" ")  # size 10 bytes
            hdr += b"`\n"                           # ar header magic 2 bytes
            assert len(hdr) == 60, f"ar header size wrong: {len(hdr)} (expected 60)"
            out.write(hdr)
            out.write(body)
            if len(body) % 2 == 1:
                out.write(b"\n")

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print(f"usage: {sys.argv[0]} out.ipk debian-binary control.tar.gz data.tar.gz", file=sys.stderr)
        sys.exit(2)
    build_ar_ipk(*sys.argv[1:])
