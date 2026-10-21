#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pack a static init binary into a gzip'd newc initramfs.

Usage: mkinitramfs.py <init-binary> <out.img>

The archive holds /init, empty /proc /sys /dev, and a /dev/console node so the
kernel can hand init its console on fds 0-2. Output is reproducible (fixed
mtimes, uid/gid 0), so the same init binary always gives the same image.
"""
import gzip
import io
import sys


def _entry(name, mode, data=b"", rdev=(0, 0), ino=1):
    name_b = name.encode() + b"\0"
    hdr = "070701" + "".join(
        f"{v:08x}"
        for v in (
            ino, mode, 0, 0, 1, 0, len(data),  # ino mode uid gid nlink mtime size
            0, 0, rdev[0], rdev[1],            # devmajor devminor rdevmajor rdevminor
            len(name_b), 0,                    # namesize check
        )
    )
    out = hdr.encode() + name_b
    out += b"\0" * (-len(out) % 4)
    out += data
    out += b"\0" * (-len(out) % 4)
    return out


def build(init_bytes):
    S_IFDIR, S_IFREG, S_IFCHR = 0o040000, 0o100000, 0o020000
    parts = [
        _entry("dev", S_IFDIR | 0o755, ino=1),
        _entry("dev/console", S_IFCHR | 0o600, rdev=(5, 1), ino=2),
        _entry("proc", S_IFDIR | 0o755, ino=3),
        _entry("sys", S_IFDIR | 0o755, ino=4),
        _entry("init", S_IFREG | 0o755, init_bytes, ino=5),
        _entry("TRAILER!!!", 0, ino=0),
    ]
    raw = b"".join(parts)
    raw += b"\0" * (-len(raw) % 512)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0, compresslevel=9) as gz:
        gz.write(raw)
    return buf.getvalue()


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as f:
        init_bytes = f.read()
    with open(sys.argv[2], "wb") as f:
        f.write(build(init_bytes))


if __name__ == "__main__":
    main()
