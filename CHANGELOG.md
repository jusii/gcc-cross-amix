# Changelog

## 2026-09-29 — the wrapper keeps gcc -d<X> flags off ld; the sysroot is guarded

A link with `-dM` could make ld take the next argument, the sysroot libc.so.1, as a map file and overwrite it (it did, 2026-09-28). `make sysroot` leaves the stock files read-only; a `sysroot-check` target and env.sh refuse a non-ELF libc.

## 2026-09-28 — AMIX_USER_CFLAGS keeps volatile and const; test gates reinstall only the wrapper

The same -Dvolatile=__volatile__ -Dconst=__const__ pair as AMIX_KERNEL_CFLAGS, for user-space builds under -traditional. The test targets no longer reinstall binutils and gcc into the prefix.

## 2026-09-27 — AMIX_KERNEL_CFLAGS keeps volatile and const under -traditional (7a1d727)

`-Dvolatile=__volatile__ -Dconst=__const__` added next to `-Dinline=__inline__`. Under `-traditional` the
stock `<sys/types.h>` defined `volatile` and `const` as empty, so gcc deleted `spl6()`/`splx()` from
`<sys/inline.h>` (their asm lost its volatile) and stopped treating MMIO accesses as volatile (review T-9).
New gate `make test-kernel-volatile`; README section "Kernel CFLAGS: -traditional and volatile". Every
kernel object built with the old flags was rebuilt (kerntools 5adc175).

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
  instead of hanging. A workspace-wide scan found no clobbered source.
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
