#!/usr/bin/env python3
"""Refuse to ship a kernel and kernel modules that cannot load together.

WHY THIS EXISTS
---------------
On 2026-09-20 the kernel was rebuilt with CONFIG_TIPC=y and flashed WITHOUT
refreshing device-files/payload/usr/lib/halium/modules/wlan.ko.  The vermagic
string was unchanged ("4.19.324-perf-g8bd8dca04eac-dirty"), so nothing looked
wrong -- but this kernel is built with CONFIG_MODVERSIONS, and enabling TIPC
shifted the genksyms CRC of 147 symbols the wlan driver imports, skb_dequeue
and the whole cfg80211_*/cnss_* family among them.  insmod rejected the module,
the phone booted perfectly with NO WIFI, and since wifi is the only way in, it
looked exactly like a hung boot.  It cost a physical power cycle and an hour.

vermagic is NOT enough.  Compare the CRCs.

The fix for that shipped a SECOND way to fail (2026-09-23): the modules were
re-copied from obj/KERNEL_OBJ/, where they are UNSIGNED -- the build only signs
them at the modules_install step (CONFIG_MODULE_SIG_ALL), into
obj/PACKAGING/kernel_modules_intermediates/.  This kernel has
CONFIG_MODULE_SIG_FORCE=y, so insmod said "Required key not available" and,
again, the phone booted with no wifi.  Stripping a signed module (llvm-strip)
also destroys the signature.  So with --cert, every module's appended PKCS#7
signature is also verified against the kernel's signing certificate.

USAGE
    check-module-abi.py [--cert signing_key.x509] <Module.symvers> <module.ko>...
Exits non-zero and names the offending symbols if any module disagrees.
"""
import os, struct, subprocess, sys, tempfile

SIG_MAGIC = b"~Module signature appended~\n"


def signature_problem(path, cert):
    """None if the module carries a valid signature from `cert`, else why not."""
    d = open(path, "rb").read()
    if not d.endswith(SIG_MAGIC):
        return "UNSIGNED (take it from kernel_modules_intermediates, do not strip)"
    info = d[-len(SIG_MAGIC) - 12:-len(SIG_MAGIC)]
    siglen, = struct.unpack(">I", info[8:12])
    end = len(d) - len(SIG_MAGIC) - 12
    if info[2] != 2 or siglen <= 0 or siglen > end:
        return "malformed signature trailer"
    with tempfile.TemporaryDirectory() as t:
        sig, body = os.path.join(t, "sig"), os.path.join(t, "body")
        open(sig, "wb").write(d[end - siglen:end])
        open(body, "wb").write(d[:end - siglen])
        r = subprocess.run(["openssl", "cms", "-verify", "-binary",
                            "-inform", "DER", "-in", sig, "-content", body,
                            "-certfile", cert, "-nointern", "-noverify",
                            "-out", os.devnull],
                           capture_output=True, text=True)
    if r.returncode != 0:
        return "signature does not verify against " + cert
    return None


def module_versions(path):
    """Return {symbol: crc} from a module's __versions section."""
    d = open(path, "rb").read()
    if d[:4] != b"\x7fELF":
        raise SystemExit(f"{path}: not an ELF file")
    e_shoff, = struct.unpack_from("<Q", d, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    secs = []
    for i in range(e_shnum):
        v = struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + i * e_shentsize)
        secs.append({"name": v[0], "off": v[4], "size": v[5]})
    sh = secs[e_shstrndx]
    for s in secs:
        end = d.index(b"\0", sh["off"] + s["name"])
        s["n"] = d[sh["off"] + s["name"]:end].decode()
    ver = [s for s in secs if s["n"] == "__versions"]
    if not ver:
        return {}          # built without MODVERSIONS: nothing to check
    out = {}
    blob = d[ver[0]["off"]:ver[0]["off"] + ver[0]["size"]]
    for i in range(0, len(blob), 64):
        crc, = struct.unpack_from("<Q", blob, i)
        name = blob[i + 8:i + 64].split(b"\0")[0].decode(errors="replace")
        if name:
            out[name] = crc & 0xFFFFFFFF
    return out


def kernel_symbols(symvers):
    out = {}
    for line in open(symvers, encoding="utf-8", errors="replace"):
        p = line.split()
        if len(p) >= 2:
            try:
                out[p[1]] = int(p[0], 16) & 0xFFFFFFFF
            except ValueError:
                pass
    return out


def main(argv):
    cert = None
    if len(argv) > 2 and argv[1] == "--cert":
        cert = argv[2]
        argv = argv[:1] + argv[3:]
    if len(argv) < 3:
        raise SystemExit(__doc__)
    kern = kernel_symbols(argv[1])
    if not kern:
        raise SystemExit(f"{argv[1]}: no symbols parsed")
    rc = 0
    for ko in argv[2:]:
        if cert:
            why = signature_problem(ko, cert)
            if why:
                rc = 1
                print(f"!! {ko} will NOT load on this kernel: {why}")
                continue
        need = module_versions(ko)
        if not need:
            print(f"   {ko}: no __versions (not MODVERSIONS), skipped")
            continue
        missing = [n for n in need if n not in kern]
        wrong = [(n, need[n], kern[n]) for n in need
                 if n in kern and kern[n] != need[n]]
        if missing or wrong:
            rc = 1
            print(f"!! {ko} will NOT load on this kernel:")
            if missing:
                print(f"     {len(missing)} symbol(s) not exported, e.g. "
                      + ", ".join(missing[:5]))
            if wrong:
                print(f"     {len(wrong)} CRC mismatch(es), e.g.")
                for n, a, b in wrong[:5]:
                    print(f"       {n}: module 0x{a:08x} kernel 0x{b:08x}")
        else:
            print(f"   {ko}: {len(need)} symbols, all match"
                  + (", signature OK" if cert else ""))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
