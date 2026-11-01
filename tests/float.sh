#!/bin/sh
# Regression test for the SGS "fsgldiv.s/fsglmul.s %fpN,%fpM" assembler fixup
# (see fix_asm in amix-gcc-wrapper.sh).  gcc spells single-precision FP multiply
# and divide as the 68881/68882 "fsglmul"/"fsgldiv"; config/m68k/amix.h defines
# FSGLMUL_USE_S/FSGLDIV_USE_S, so the REGISTER-TO-REGISTER form comes out with an
# SGS ".s" suffix.  GNU as 2.8.1 requires ".x" there: with both operands in FPU
# registers the data is 80-bit extended by definition, and the single-precision
# rounding is encoded in the "sgl" of the mnemonic, not in the suffix.
#
# This gate compiles float "/" and "*" through the wrapper at both
# -O0 and -O and checks the *object code* for BOTH halves of the fix:
#   (a) the register-to-register ops became the ".x" form, i.e. they disassemble
#       as "fsgldivx %fpN,%fpM" / "fsglmulx %fpN,%fpM"; and
#   (b) the legal single-precision NON-register-source ops were NOT touched --
#       a memory source ("fsgldivs %fp@(N),%fpM") and a data-register source
#       ("fsglmuls %dN,%fpM") are both valid and encode a genuinely different
#       instruction (R/M=1, source format "single") from the ".x" register form
#       (R/M=0), so rewriting them would be a miscompile.  gcc emits all three
#       shapes from the source below.
#
# Failure mode against the PRE-FIX wrapper (proof this test bites): it fails at
# ASSEMBLY time, before any objdump check runs --
#   Error: operands mismatch -- statement `fsgldiv.s %fp1,%fp0' ignored
# which is exactly why cross-building C that divides or multiplies "float"
# previously needed a -Dfloat=double workaround.  A too-greedy rewrite that also
# hit the memory/data-register forms fails check (b) instead.
. "$(dirname "$0")/lib.sh"
printf '%s\n' \
	'/* Single-precision multiply/divide in three operand shapes.' \
	'   rr_*  : both operands end up in FPU registers -- the form GNU as' \
	'           rejects when it carries the SGS ".s" suffix (the bug).' \
	'   mem_* : single-precision MEMORY source -- ".s" is legal and must' \
	'           NOT be rewritten.' \
	'   dreg  : single-precision DATA-REGISTER source -- likewise legal.' \
	'   Deliberately no float COMPARISONS: the SGS fcmp operand order is a' \
	'   separate fixup with its own gate, "make test-fcmp". */' \
	'float rr_div (float a, float b) { float t = a + b; return (a * t) / (b * t); }' \
	'float rr_mul (float a, float b) { float t = a + b; return (a * t) * (b * t); }' \
	'float mem_div(float a, float b) { return a / b; }' \
	'float mem_mul(float a, float b) { return a * b; }' \
	'float dreg   (float a, float b) { return (a * b) * (a + b); }' \
	'int main(void) { return (int)(rr_div(6.0f, 3.0f) + rr_mul(1.0f, 1.0f)' \
	'                            + mem_div(8.0f, 4.0f) + mem_mul(2.0f, 3.0f)' \
	'                            + dreg(1.0f, 2.0f)); }' \
	> $W/float.c
status=0; sawdreg=0; \
for opt in -O0 -O; do \
	obj="$W/float$opt.o"; \
	"$CC" $CPUFLAGS $opt -c -o "$obj" $W/float.c; \
	dis="$("$OBJDUMP" -d "$obj")"; \
	echo "==== $opt ===="; \
	printf '%s\n' "$dis" | grep -oE 'fsgl(div|mul)[sx][ \t]+[^ ]+' | sort | uniq -c || true; \
	if ! printf '%s\n' "$dis" | grep -Eq 'fsgldivx[ \t]+%fp[0-7],%fp[0-7]'; then \
		echo "FAIL$opt: no register-to-register fsgldiv in the .x form"; status=1; \
	fi; \
	if ! printf '%s\n' "$dis" | grep -Eq 'fsglmulx[ \t]+%fp[0-7],%fp[0-7]'; then \
		echo "FAIL$opt: no register-to-register fsglmul in the .x form"; status=1; \
	fi; \
	if ! printf '%s\n' "$dis" | grep -Eq 'fsgldivs[ \t]+%fp@\('; then \
		echo "FAIL$opt: legal memory-source fsgldiv.s was rewritten away"; status=1; \
	fi; \
	if ! printf '%s\n' "$dis" | grep -Eq 'fsglmuls[ \t]+%fp@\('; then \
		echo "FAIL$opt: legal memory-source fsglmul.s was rewritten away"; status=1; \
	fi; \
	if printf '%s\n' "$dis" | grep -Eq 'fsgl(div|mul)s[ \t]+%fp[0-7],'; then \
		echo "FAIL$opt: an FPU-register-source op kept the illegal .s suffix"; status=1; \
	fi; \
	if printf '%s\n' "$dis" | grep -Eq 'fsglmuls[ \t]+%d[0-7],%fp[0-7]'; then sawdreg=1; fi; \
done; \
test $sawdreg -eq 1 || { echo "FAIL: legal data-register-source fsglmul.s never seen"; status=1; }; \
test $status -eq 0 && echo "test-float PASS: reg-reg fsgl ops are .x, memory/data-register .s forms untouched"
exit $status
