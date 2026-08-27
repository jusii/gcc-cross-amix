# Changelog

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
