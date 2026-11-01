# Changelog

## 2026-11-01 — the assembler wrapper keeps option values with their options (b39e6c0)

`-Wa,--defsym,SYM=1` and `-Wa,-I,dir` failed with "amix as wrapper: more than one input" because the assembler wrapper treated only `-o` as taking a separate value. It now reads options the way GNU as 2.8.1 does (getopt_long_only over gas/as.c and the m68k ELF table in tc-m68k.c): the short options `-I -o -A -m -Q` take a value attached or as the next word, `-a` only attached, and the long options `--defsym --emulation --itbl` as `=val` or the next word, with one dash or abbreviated. Two real inputs are still refused. New gate `make test-asopts`. 164 kernel, port and libgcc objects are byte-identical before and after.

## 2026-11-01 — every compile path gets fix_asm; the review fixes (7e7af94..56f8545)

Every compile goes through gcc.real and an assembler wrapper that runs fix_asm on compiler output, so `.i` input,
`-S` then `-c`, `-pipe`, `-save-temps` and `-x c` no longer bypass the repairs. Linker options are an explicit list;
everything else goes to the compiler. gcc is built as 32-bit code to match its i686 configuration (cpp's `#if`
arithmetic is 32-bit). Links search usr/lib then usr/ccs/lib, use libc's static part and values-X?.o, and leave no
temporary files. fix_asm rules 5 and 6 extended; rules 2–11 in one perl run. New opt-in `-m68060`. libgcc gains the
missing float conversions. Pinned distfile sha256, patches/, pinned config.guess/sub, a stamp-file make graph,
stripped path-free binaries, a required AMIX_ROOT; gates as scripts under tests/, run against a staged copy.
LICENSING-STATUS.md maps authorship. Kernel output byte-identical (dlm core, loader, modules, the k30 cut, libgcc).

## 2026-10-31 — README and CHANGELOG wording (c97cf2f)

Internal review ids and a hash from another repository's private branch removed; no change to the toolchain.

## 2026-10-05 — 68060-safe integer code by default; scan060 (2ab2b22, 80b6d67)

gcc 2.7.2.3 emits the 64-bit-product `muls.l/mulu.l <ea>,%dH:%dL` for every divide or modulo by a constant and
for (u64)a*b, and a 68060 traps on it (vector 61). fix_asm now rewrites each one into 16x16 `mulu.w` partial
products with the same result, registers and CCR (X included); any 64-bit multiply or divide left afterwards
fails the compile. Opt out with `AMIX_MUL64=keep` or `-mmul64`. An object without the form is byte-identical.
New `m68k-cbm-sysv4-scan060` (optional `AMIX_SCAN060=1` post-check), which also finds switch tables in
executables linked at 0x80000000. Gates test-mul64, test-mul64-run (qemu 68020/68060), test-scan060.
README: gcc 2.7.2.3 has no -m68060; use -m68040 for 040/060 code.

## 2026-09-29 — the wrapper keeps gcc -d<X> flags off ld; the sysroot is guarded

A link with `-dM` could make ld take the next argument, the sysroot libc.so.1, as a map file and overwrite it (it did, 2026-09-28). `make sysroot` leaves the stock files read-only; a `sysroot-check` target and env.sh refuse a non-ELF libc.

## 2026-09-28 — AMIX_USER_CFLAGS keeps volatile and const; test gates reinstall only the wrapper

The same -Dvolatile=__volatile__ -Dconst=__const__ pair as AMIX_KERNEL_CFLAGS, for user-space builds under -traditional. The test targets no longer reinstall binutils and gcc into the prefix.

## 2026-09-27 — AMIX_KERNEL_CFLAGS keeps volatile and const under -traditional (7a1d727)

`-Dvolatile=__volatile__ -Dconst=__const__` added next to `-Dinline=__inline__`. Under `-traditional` the
stock `<sys/types.h>` defined `volatile` and `const` as empty, so gcc deleted `spl6()`/`splx()` from
`<sys/inline.h>` (their asm lost its volatile) and stopped treating MMIO accesses as volatile.
New gate `make test-kernel-volatile`; README section "Kernel CFLAGS: -traditional and volatile". Every
kernel object built with the old flags was rebuilt.

## 2026-09-15

- wrapper: "-c" with no "-o" no longer forwards an EMPTY "-o" to the real compiler
  (1bfffbd). 8ca9e3b fixed only the *.c branch of the -c dispatch; the branch that
  takes .s/.S/.i inputs still passed "-o $compile_out" unconditionally. gcc 2.7.2.3
  drops an empty argument, so the assembler ran as "as -V -Qy -o ../src/foo.s" --
  the source became the output file and stdin the input: "cc -c foo.s" wrote an
  object OVER THE ASSEMBLY SOURCE, produced no .o and exited 0 (hung on a terminal).
  The branch now passes -o only when one was given. "make test-objdir" covers .c,
  .s and .S (object in the cwd, source dir clean, source byte-identical, explicit -o
  honoured, .S preprocessed) and reads /dev/null so a reintroduced empty -o fails
  instead of hanging. A scan of the source trees built with the wrapper found no
  clobbered source.
- README: corrected the scope of the "-c with no -o" change (7036952) -- the
  discriminator is the working directory versus the source's own directory, so a
  non-recursive Makefile compiling "sub/foo.c" from the tree top is affected as a
  VPATH build is; the .s/.S half documented.
- wrapper: "-c" with no "-o" writes the object into the working directory, as gcc
  does, instead of next to the source (8ca9e3b) -- every VPATH/objdir build got its
  objects in the source tree; "make test-objdir" added.
- wrapper: "-lNAME" is linked as "-L<dir> -lNAME" so DT_NEEDED records the bare name
  (cc84d5b); host paths were being baked into DT_NEEDED for every SONAME-less DSO
  (all but libc), so cross-linked X/socket programs died at exec on the guest;
  "make test-dtneeded" added. Dynamic socket/X binaries must be relinked.
- Known, open: ".i" inputs bypass the wrapper's assembler repairs (gcc.real assembles
  them internally) and yield the broken 64-bit "divsl" -- do not feed .i files to the
  wrapper; the "-x LANG" parse gap; the /usr/ccs/lib stub archive; sysroot-target
  idempotency.
## 2026-08-27

- asm-fixup: bit-field operands. gcc copies an inline "asm" template through
  verbatim, so portable m68k C that writes the bit-field offset/width the
  Motorola way ("bfffo %d3{#0:#32},%d2") hands GNU as 2.8.1 a "#" it treats as
  a comment introducer — the rest of the line is scrubbed and the instruction
  is lost. fix_asm now rewrites "#" to "&" (this target's immediate prefix)
  inside the bit-field braces, for all eight bit-field mnemonics; register
  offsets/widths and the already-correct "&" form are left alone. New gate
  "make test-bitfield" checks the encoding, not just that the file assembled.
  No change to generated code: 89 AMIX kernel objects are byte-identical
  before and after.
