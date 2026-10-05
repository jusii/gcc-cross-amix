#!/usr/bin/env python3
# @TARGET@-scan060 -- find instructions the 68060 does not implement.
#
# Usage: @TARGET@-scan060 [--quiet] <object|archive|executable|dir> [...]
#        @TARGET@-scan060 --self-test
#
# Exit: 0 every inspected ELF is clean; 2 at least one hit, or nothing was
#       inspected at all; 1 a usage or tool error.
#
# The 68060 raises vector 61 ("unimplemented integer instruction") for these
# 68020/030/040 integer forms, and AMIX has no software emulation for them, so
# a process that executes one is killed:
#
#   MULU.L/MULS.L <ea>,Dh:Dl   32x32 -> 64 product   0x4C00-0x4C3F, ext bit 10
#   DIVU.L/DIVS.L <ea>,Dr:Dq   64/32 dividend        0x4C40-0x4C7F, ext bit 10
#   MOVEP, CMP2, CHK2, CAS2    (and CAS on a misaligned operand, which no
#                              static scan can see)
#
# The decision is made from the ENCODING, never from the mnemonic: objdump
# spells the 64-bit divide "divsl" and the 32-bit remainder divide "divsll",
# and older objdumps print both register pairs with a comma, so a mnemonic or
# colon grep is wrong in one direction or the other.
#
# objdump disassembles .text linearly, and gcc's switch jump tables are data
# inside .text: decoded as code they read as movep/ori noise.  Each
# "jmp %pc@(T,%dN:w)" dispatch is followed to its table, the table is measured
# (it ends at the nearest case label it points to) and only the code between
# tables is decoded.  Every hit is printed with its address and enclosing
# symbol so it can be checked by hand.
#
# This is the 68060 gate the cross gcc wrapper runs when AMIX_SCAN060=1 is set;
# it can also be pointed at any object, archive, executable or directory.

import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

TARGET = "@TARGET@"
HERE = os.path.dirname(os.path.abspath(__file__))
ELF_MAGIC = b"\x7fELF"
AR_MAGIC = b"!<arch>\n"

LINE = re.compile(r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{4} )+)\s*(\S+)\s*(.*)$")
SYM = re.compile(r"^([0-9a-f]+) <([^>]+)>:\s*$")
MNEM_OTHER = re.compile(r"^(movep|cmp2|chk2|cas2)")
# gcc's switch dispatch: "jmp %pc@(T,%dN:w)" (4efb), a word table at T of
# signed offsets from T.  Both the binutils 2.8.1 and current objdump print it
# this way ("92 <sw+1c>" and "92 <sw+0x1c>" respectively).
JMPTAB = re.compile(r"^\s*([0-9a-f]+):\s+4efb [0-9a-f]{4} \s*jmp\s+"
                    r"%pc@\((?:0x)?([0-9a-f]+)\b[^)]*,%d[0-7]:w\)\s*$")


def find_tool(kind, envvar):
    """The toolchain's own tool first, then a system m68k one."""
    env = os.environ.get(envvar)
    if env:
        return env
    for cand in (os.path.join(HERE, "%s-%s" % (TARGET, kind)),):
        if os.access(cand, os.X_OK):
            return cand
    for t in ("%s-%s" % (TARGET, kind), "m68k-linux-gnu-" + kind,
              "m68k-elf-" + kind):
        p = shutil.which(t)
        if p:
            return p
    print("scan060: no m68k %s found (set %s)" % (kind, envvar),
          file=sys.stderr)
    raise SystemExit(1)


def classify(hexwords, mnem):
    """-> reason string for a 060-unimplemented instruction, or None."""
    if MNEM_OTHER.match(mnem):
        return "%s (not implemented on the 68060)" % mnem
    if len(hexwords) < 2:
        return None
    op = int(hexwords[0], 16)
    ext = int(hexwords[1], 16)
    if not (0x4C00 <= op <= 0x4C7F):
        return None
    if not (ext & 0x0400):          # SIZE clear: the 32-bit form, fine
        return None
    return "64-bit product" if op < 0x4C40 else "64-bit dividend"


def scan_listing(text):
    """-> (decoded_lines, [(addr, symbol, mnem, ops, why)])"""
    hits, total, sym = [], 0, "?"
    for raw in text.splitlines():
        s = SYM.match(raw)
        if s:
            sym = s.group(2)
            continue
        m = LINE.match(raw)
        if not m:
            continue
        total += 1
        why = classify(m.group(2).split(), m.group(3))
        if why:
            hits.append((m.group(1), sym, m.group(3), m.group(4).strip(), why))
    return total, hits


def is_m68k(data):
    """ELF32 big-endian, e_machine EM_68K (4)."""
    return (len(data) >= 20 and data[:4] == ELF_MAGIC and data[4] == 1
            and data[5] == 2 and struct.unpack(">H", data[18:20])[0] == 4)


def exec_sections(data):
    """ELF32 big-endian -> [(addr, file_offset, size)] of SHF_EXECINSTR."""
    shoff = struct.unpack(">I", data[32:36])[0]
    shentsize, shnum = struct.unpack(">HH", data[46:50])
    out = []
    for i in range(shnum):
        sh = data[shoff + i * shentsize: shoff + (i + 1) * shentsize]
        _n, typ, flags, addr, off, size = struct.unpack(">IIIIII", sh[:24])
        if typ == 1 and flags & 0x4 and size:          # PROGBITS, EXECINSTR
            out.append((addr, off, size))
    return out


def table_ranges(listing, data, secs):
    """-> [(start, end)] data ranges: dispatch filler + table, per jmp."""
    def word_at(a):
        for sa, so, sz in secs:
            if sa <= a and a + 2 <= sa + sz:
                return struct.unpack(">h", data[so + a - sa: so + a - sa + 2])[0]
        return None
    out = []
    for raw in listing.splitlines():
        m = JMPTAB.match(raw)
        if not m:
            continue
        # binutils 2.8.1 objdump on a 64-bit host prints a target at or
        # above 0x80000000 sign-extended ("ffffffff80002af4"): an AMIX
        # executable's text starts at 0x80000000, so keep 32 bits.
        jmp, t = int(m.group(1), 16), int(m.group(2), 16) & 0xffffffff
        if not (jmp < t <= jmp + 64):
            continue
        end, a, n = None, t, 0
        while n < 8192 and (end is None or a < end):
            w = word_at(a)
            if w is None:
                break
            if w > 0 and (end is None or t + w < end):
                end = t + w
            a += 2
            n += 1
        if end is not None and end > t:
            out.append((jmp + 4, end))
    return out


def run_objdump(objdump, path, lo=None, hi=None):
    cmd = [objdump, "-d"]
    if lo is not None:
        cmd += ["--start-address=0x%x" % lo, "--stop-address=0x%x" % hi]
    r = subprocess.run(cmd + [path], capture_output=True, text=True,
                       errors="replace", env=dict(os.environ, LC_ALL="C"))
    if r.returncode != 0:
        print("scan060: objdump failed on %s: %s"
              % (path, r.stderr.strip()[:160]), file=sys.stderr)
        raise SystemExit(1)
    return r.stdout


def scan_elf(path, objdump):
    """-> (decoded_lines, hits, n_tables_skipped)

    Whole-section listing first; then, if switch tables were found, decode
    only the code BETWEEN them (so the stream re-synchronises after each
    table) and repeat until no new table turns up.
    """
    with open(path, "rb") as fp:
        data = fp.read()
    secs = exec_sections(data)
    listing = run_objdump(objdump, path)
    skip = set(table_ranges(listing, data, secs))
    for _round in range(6):
        if not skip:
            break
        listing = ""
        for sa, _so, sz in secs:
            lo, hi = sa, sa + sz
            for s, e in sorted(r for r in skip if sa <= r[0] < hi):
                if s > lo:
                    listing += run_objdump(objdump, path, lo, s)
                lo = max(lo, e)
            if lo < hi:
                listing += run_objdump(objdump, path, lo, hi)
        new = set(table_ranges(listing, data, secs)) - skip
        if not new:
            break
        skip |= new
    total, hits = scan_listing(listing)
    return total, hits, len(skip)


def has_symtab(path):
    """ELF32 big-endian -> does it carry a SHT_SYMTAB section?"""
    with open(path, "rb") as fp:
        data = fp.read()
    shoff = struct.unpack(">I", data[32:36])[0]
    shentsize, shnum = struct.unpack(">HH", data[46:50])
    return any(struct.unpack(">I", data[shoff + i * shentsize + 4:
                                         shoff + i * shentsize + 8])[0] == 2
               for i in range(shnum))


def ar_members(path, tmp):
    """GNU/SVR4 ar archive -> [(member_name, extracted_path)] of m68k ELFs."""
    with open(path, "rb") as fp:
        data = fp.read()
    out, names, pos, idx = [], b"", len(AR_MAGIC), 0
    while pos + 60 <= len(data):
        hdr = data[pos:pos + 60]
        name = hdr[:16].rstrip()
        size = int(hdr[48:58].strip() or b"0")
        body = data[pos + 60: pos + 60 + size]
        pos += 60 + size + (size & 1)
        if name in (b"/", b"/SYM64/"):
            continue
        if name == b"//":
            names = body
            continue
        if name.startswith(b"/") and name[1:].isdigit():
            off = int(name[1:])
            name = names[off:names.index(b"\n", off)]
        name = name.rstrip(b"/").decode("ascii", "replace")
        if not is_m68k(body[:20]):
            continue
        idx += 1
        member = os.path.join(tmp, "%04d-%s" % (idx, os.path.basename(name)))
        with open(member, "wb") as fp:
            fp.write(body)
        out.append((name, member))
    return out


def targets_of(path, tmp):
    """-> [(label, elf_path)] for one command-line argument."""
    if os.path.isdir(path):
        out = []
        for dirpath, dirnames, filenames in os.walk(path):
            dirnames.sort()
            for f in sorted(filenames):
                full = os.path.join(dirpath, f)
                if os.path.islink(full) or not os.path.isfile(full):
                    continue
                rel = os.path.relpath(full, path)
                out += [(rel + l[len(f):], e)
                        for l, e in targets_of(full, tmp)]
        return out
    with open(path, "rb") as fp:
        head = fp.read(20)
    if is_m68k(head):
        return [(os.path.basename(path), path)]
    if head.startswith(AR_MAGIC):
        base = os.path.basename(path)
        return [("%s(%s)" % (base, n), e) for n, e in ar_members(path, tmp)]
    return []


TABLE = ("f:\n\tjmp 6(%pc,%d0.w)\n\t.long 2\n"
         ".T:\n\t.word 0x0108\n\t.word 0x0108\n\t.space 0x104\n")

SELF_TEST = [
    # (assembler body, expect a hit, what it is)
    ("\t.word 0x4c6e,0x1c02,0x0010\n", True,
     "divs.l 16(%fp),%d2:%d1  (64-bit dividend)"),
    ("\t.word 0x4c6e,0x1802,0x0010\n", False,
     "divsl.l 16(%fp),%d2:%d1 (32-bit remainder)"),
    ("\t.word 0x4c3c,0x0401,0x0000,0x0005\n", True,
     "mulu.l &5,%d1:%d0       (64-bit product)"),
    ("\t.word 0x4c3c,0x0001,0x0000,0x0005\n", False,
     "mulu.l &5,%d0           (32-bit product)"),
    ("\t.word 0x4c41,0x0000\n", False,
     "divu.l %d1,%d0          (32-bit)"),
    ("\t.word 0x0108,0x0000\n", True,
     "movep.w 0(%a0),%d0"),
    ("\tdivsl.l 16(%fp),%d2:%d1\n", False,
     "divsl.l as assembled    (32-bit remainder)"),
    ("\tmulu.l &5,%d1:%d0\n", True,
     "mulu.l as assembled     (64-bit product)"),
    # a switch dispatch whose table entries (0x0108) decode as movep when
    # read as code: the table must be skipped, the code after it scanned
    (TABLE + "\tnop\n\trts\n", False,
     "switch table read as movep, skipped"),
    (TABLE + "\tmulu.l &5,%d1:%d0\n\trts\n", True,
     "code after a switch table still scanned"),
]

# The same shapes linked at 0x80000000, where AMIX executables start, and
# stripped: no symbols, and binutils 2.8.1 objdump prints the table address
# sign-extended.
SELF_TEST_LINKED = [
    (TABLE + "\tnop\n\trts\n", False,
     "stripped executable: switch table skipped"),
    (TABLE + "\tmovep.w 0(%a0),%d0\n\trts\n", True,
     "stripped executable: movep after a table"),
    (TABLE + "\tmulu.l &5,%d1:%d0\n\trts\n", True,
     "stripped executable: 64-bit product"),
]


def self_test():
    """Prove the detector fires, on bytes this toolchain really produced."""
    objdump = find_tool("objdump", "AMIX_OBJDUMP")
    asm = find_tool("as", "AMIX_AS")
    ld = find_tool("ld", "AMIX_LD")
    strip = find_tool("strip", "AMIX_STRIP")
    cases = [c + (False,) for c in SELF_TEST]
    cases += [c + (True,) for c in SELF_TEST_LINKED]
    ok = True
    with tempfile.TemporaryDirectory(prefix="scan060-st.") as tmp:
        for i, (body, want, what, linked) in enumerate(cases):
            s = os.path.join(tmp, "p%d.s" % i)
            o = os.path.join(tmp, "p%d.o" % i)
            with open(s, "w") as fp:
                fp.write("\t.text\n" + body)
            steps = [[asm, "-m68020", "-o", o, s]]
            if linked:
                x = os.path.join(tmp, "p%d" % i)
                steps += [[ld, "-Ttext", "0x80000000", "-e", "f", "-o", x, o],
                          [strip, x]]
                o = x
            for cmd in steps:
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode != 0:
                    break
            if r.returncode != 0:
                print("  FAIL %-44s -> %s: %s" % (what, os.path.basename(
                      cmd[0]), r.stderr.strip()[:80]))
                ok = False
                continue
            if linked and has_symtab(o):
                print("  FAIL %-44s -> strip left a symbol table" % what)
                ok = False
                continue
            total, hits, ntab = scan_elf(o, objdump)
            res = "ok" if (bool(hits) == want and total) else "FAIL"
            if ".T:" in body:
                # the table case must bite: read linearly, the table is a hit
                _t, raw = scan_listing(run_objdump(objdump, o))
                if not raw or ntab != 1:
                    res = "FAIL"
            ok = ok and res == "ok"
            print("  %-4s %-44s -> %s" % (res, what,
                  hits[0][4] if hits else "clean"))
    print("self-test: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 2


def main(argv):
    if "--self-test" in argv:
        return self_test()
    quiet = "--quiet" in argv
    paths = [a for a in argv if not a.startswith("-")]
    unknown = [a for a in argv if a.startswith("-") and a != "--quiet"]
    if not paths or unknown:
        print("usage: %s-scan060 [--quiet] <object|archive|executable|dir> ..."
              "\n       %s-scan060 --self-test" % (TARGET, TARGET),
              file=sys.stderr)
        return 1
    objdump = find_tool("objdump", "AMIX_OBJDUMP")
    rc, n_elf, n_hit = 0, 0, 0
    with tempfile.TemporaryDirectory(prefix="scan060.") as tmp:
        for p in paths:
            elfs = targets_of(p, tmp)
            if not elfs:
                print("scan060: %s: NOTHING INSPECTED -- no m68k ELF found; "
                      "that is not a pass" % p)
                rc = 2
                continue
            for label, e in elfs:
                total, hits, ntab = scan_elf(e, objdump)
                n_elf += 1
                if hits or not quiet:
                    verdict = "CLEAN" if not hits else "HITS %d" % len(hits)
                    print("  %-9s %s (%d insns, %d switch tables skipped)"
                          % (verdict, label, total, ntab))
                for addr, sym, mnem, ops, why in hits:
                    print("      %s <%s> %s %s  -- %s"
                          % (addr, sym, mnem, ops, why))
                if hits:
                    n_hit += 1
                    rc = 2
    if not quiet or rc:
        print("scan060: %d ELF(s) inspected, %d with 68060-unimplemented "
              "integer instructions" % (n_elf, n_hit))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
