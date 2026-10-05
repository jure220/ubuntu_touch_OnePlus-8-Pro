#!/usr/bin/env python3
"""Allocate extra binderfs nodes (waydroid wants its own binder domain)."""
import fcntl, struct, sys, os

NRBITS, TYPEBITS, SIZEBITS = 8, 8, 14
NRSHIFT = 0
TYPESHIFT = NRSHIFT + NRBITS
SIZESHIFT = TYPESHIFT + TYPEBITS
DIRSHIFT = SIZESHIFT + SIZEBITS
READ, WRITE = 0x2, 0x1
def IOC(d, t, nr, size): return (d << DIRSHIFT) | (t << TYPESHIFT) | (nr << NRSHIFT) | (size << SIZESHIFT)
BINDER_CTL_ADD = IOC(READ | WRITE, 98, 1, 264)

nodes = sys.argv[1:] or ["anbox-binder", "anbox-vndbinder", "anbox-hwbinder"]
fd = open("/dev/binderfs/binder-control", "rb")
for n in nodes:
    buf = struct.pack("256sII", n.encode(), 0, 0)
    try:
        res = fcntl.ioctl(fd.fileno(), BINDER_CTL_ADD, buf)
        name, major, minor = struct.unpack("256sII", res)
        print(f"OK   {n}: major={major} minor={minor}")
    except FileExistsError:
        print(f"EXIST {n}")
    except Exception as e:
        print(f"FAIL {n}: {e}")
