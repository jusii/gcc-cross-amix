#!/bin/sh
# Regression test for the SGS/Motorola bit-field operand assembler fixup (see
# fix_asm in amix-gcc-wrapper.sh).  gcc copies an inline "asm" template into its
# output verbatim, so portable m68k C that writes the bit-field offset and width
# the Motorola way -- "bfffo %d3{#0:#32},%d2" -- hands GNU as 2.8.1 a "#" it
# treats as a COMMENT introducer (line_comment_chars in gas/config/tc-m68k.c;
# the immediate prefix on this target is "&").  The rest of the line disappears
# and the instruction is lost.  The wrapper rewrites the "#" inside the braces
# to "&", the spelling gcc's own bit-field patterns already emit.
#
# This gate drives all eight m68k bit-field mnemonics through the installed
# wrapper at both -O0 and -O and checks the *object code*.  Asserting only that
# the file assembled would be worthless -- a mangled offset or width assembles
# just as quietly -- so the awk below decodes each instruction's EXTENSION WORD
# and requires:
#   (a) offset in bits 10:6 and width in bits 4:0 to equal the values the C
#       source asked for (each site uses a different pair; a width of 32
#       encodes as 0), with the Do/Dw register-select bits CLEAR; and
#   (b) the two controls to come through untouched -- ctl_amp, already spelled
#       "{&7:&9}", and ctl_reg, whose offset and width are REGISTERS
#       ("{%d2:%d3}", Do=1 Dw=1), which a careless rewrite would corrupt.
# The extension word's register field is deliberately not pinned: it follows
# register allocation and differs between -O0 and -O.
#
# Failure mode against the PRE-FIX wrapper (proof this test bites): it fails at
# ASSEMBLY time, before any objdump check runs, with eight pairs of
#   Error: Missing operand
#   Error: operands mismatch -- statement `bfffo %d0{' ignored
# while the two controls assemble cleanly.
. "$(dirname "$0")/lib.sh"
printf '%s\n' \
	'/* Hand-written Motorola-syntax bit-field inline asm, "{#offset:#width}".' \
	'   gcc copies an asm template through verbatim, so this is exactly what' \
	'   reaches the assembler.  Every site uses a DISTINCT offset/width pair so' \
	'   the objdump check can prove the numbers survived the rewrite and not' \
	'   merely that the line assembled.  ctl_* are the untouched controls. */' \
	'unsigned int bf_ffo (unsigned int x) { unsigned int n; __asm__("bfffo %1{#0:#32},%0"   : "=d"(n) : "d"(x)); return n; }' \
	'unsigned int bf_extu(unsigned int x) { unsigned int n; __asm__("bfextu %1{#7:#9},%0"   : "=d"(n) : "d"(x)); return n; }' \
	'int          bf_exts(unsigned int x) { int n;          __asm__("bfexts %1{#11:#13},%0" : "=d"(n) : "d"(x)); return n; }' \
	'unsigned int bf_ins (unsigned int x, unsigned int v) { __asm__("bfins %1,%0{#3:#5}"    : "=d"(x) : "d"(v), "0"(x)); return x; }' \
	'int          bf_tst (unsigned int x) { int n;          __asm__("bftst %1{#4:#8}\n\tsne %0" : "=d"(n) : "d"(x)); return n; }' \
	'unsigned int bf_clr (unsigned int x) {                 __asm__("bfclr %0{#17:#6}"      : "=d"(x) : "0"(x)); return x; }' \
	'unsigned int bf_set (unsigned int x) {                 __asm__("bfset %0{#21:#2}"      : "=d"(x) : "0"(x)); return x; }' \
	'unsigned int bf_chg (unsigned int x) {                 __asm__("bfchg %0{#25:#3}"      : "=d"(x) : "0"(x)); return x; }' \
	'/* control: already spelled with this assembler immediate prefix "&" -- no change */' \
	'unsigned int ctl_amp(unsigned int x) { unsigned int n; __asm__("bfextu %1{&7:&9},%0"   : "=d"(n) : "d"(x)); return n; }' \
	'/* control: offset and width in REGISTERS -- must not change */' \
	'unsigned int ctl_reg(unsigned int x, int o, int w) { unsigned int n; __asm__("bfextu %1{%2:%3},%0" : "=d"(n) : "d"(x), "d"(o), "d"(w)); return n; }' \
	> $W/bitfield.c
status=0; \
for opt in -O0 -O; do \
	obj="$W/bitfield$opt.o"; \
	"$CC" $CPUFLAGS $opt -c -o "$obj" $W/bitfield.c; \
	echo "==== $opt ===="; \
	"$OBJDUMP" -d "$obj" | awk ' \
		function hex(s,  i,c,v,n) { n=0; s=tolower(s); \
			for (i=1;i<=length(s);i++) { c=substr(s,i,1); v=index("0123456789abcdef",c)-1; \
				if (v<0) return -1; n=n*16+v } \
			return n } \
		BEGIN { \
			mn["bf_ffo"] ="bfffo";  wo["bf_ffo"] = 0; ww["bf_ffo"] =32; \
			mn["bf_extu"]="bfextu"; wo["bf_extu"]= 7; ww["bf_extu"]= 9; \
			mn["bf_exts"]="bfexts"; wo["bf_exts"]=11; ww["bf_exts"]=13; \
			mn["bf_ins"] ="bfins";  wo["bf_ins"] = 3; ww["bf_ins"] = 5; \
			mn["bf_tst"] ="bftst";  wo["bf_tst"] = 4; ww["bf_tst"] = 8; \
			mn["bf_clr"] ="bfclr";  wo["bf_clr"] =17; ww["bf_clr"] = 6; \
			mn["bf_set"] ="bfset";  wo["bf_set"] =21; ww["bf_set"] = 2; \
			mn["bf_chg"] ="bfchg";  wo["bf_chg"] =25; ww["bf_chg"] = 3; \
			mn["ctl_amp"]="bfextu"; wo["ctl_amp"]= 7; ww["ctl_amp"]= 9; \
		} \
		/^[0-9a-f]+ <.*>:/ { fn=$2; gsub(/[<>:]/,"",fn); next } \
		{ \
			op=""; \
			for (i=1;i<=NF;i++) if ($i ~ /^bf(chg|clr|exts|extu|ffo|ins|set|tst)$/) { op=$i; ext=$(i-1); break } \
			if (op == "") next; \
			n=hex(ext); do_bit=int(n/2048)%2; off=int(n/64)%32; dw_bit=int(n/32)%2; wid=n%32; sites++; \
			if (fn == "ctl_reg") { \
				if (op == "bfextu" && do_bit == 1 && dw_bit == 1) \
					printf "  ok   %-8s %s ext=%s: register offset/width left alone (Do=1 Dw=1)\n", fn, op, ext; \
				else { \
					printf "  FAIL %-8s register bit-field form damaged: %s ext=%s Do=%d Dw=%d\n", fn, op, ext, do_bit, dw_bit; bad=1 \
				} \
				next \
			} \
			if (!(fn in mn)) { printf "  FAIL %-8s unexpected bit-field instruction %s\n", fn, op; bad=1; next } \
			if (op == mn[fn] && do_bit == 0 && dw_bit == 0 && off == wo[fn] && wid == ww[fn]%32) \
				printf "  ok   %-8s %s ext=%s: offset %d width %d intact\n", fn, op, ext, wo[fn], ww[fn]; \
			else { \
				printf "  FAIL %-8s expected %s offset %d width %d, got %s offset %d width %d (Do=%d Dw=%d ext=%s)\n", \
					fn, mn[fn], wo[fn], ww[fn], op, off, wid, do_bit, dw_bit, ext; bad=1 \
			} \
		} \
		END { \
			if (sites != 10) { printf "  FAIL: expected 10 bit-field sites, saw %d\n", sites; bad=1 } \
			exit bad ? 1 : 0 \
		}' || status=1; \
done; \
test $status -eq 0 && echo "test-bitfield PASS: all eight bit-field mnemonics assemble, offset/width encodings intact"
exit $status
