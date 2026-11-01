#!/bin/sh
# Regression test for the SGS "tdivs.l/tdivu.l <ea>,%dR:%dQ" assembler fixup
# (see fix_asm in amix-gcc-wrapper.sh).  gcc emits the 68020 32/32 divide-with-
# remainder for every variable-divisor "%"/"/"; GNU as 2.8.1 mis-assembles the
# raw SGS spelling as the 64-bit-dividend "DIVS.L Dr:Dq" (SIZE bit set), which
# overflows and leaves the operands unchanged -> wrong results.  The wrapper
# rewrites it to "divsl.l"/"divul.l" (32-bit dividend, 32r:32q).  This gate
# compiles signed+unsigned "%"/"/" through the wrapper at both the
# -O0 and -O register shapes and checks the *object code*: every emitted divide
# must disassemble as the 32-bit-dividend form ("divsll"/"divull", SIZE clear,
# both registers preserved) and NONE as the broken 64-bit form ("divsl"/"divul").
#
# Failure mode against the PRE-FIX wrapper (proof this test bites): the modulo
# ops assemble to the 64-bit "divsl"/"divul" form, so the "no broken form" check
# below fails; at -O0 the divides do too, so the "correct form present" check
# also fails.  A pass therefore requires the fixup to be installed.
. "$(dirname "$0")/lib.sh"
printf '%s\n' \
	'/* Variable-divisor signed+unsigned % and / force gcc to emit the' \
	'   68020 32/32 divide-with-remainder (SGS tdivs.l/tdivu.l ea,%dR:%dQ).' \
	'   Known answers on target: smod/umod(351,151)=49, sdiv/udiv(351,151)=2.' \
	'   The objdump check in tests/divmod.sh is what gates the test. */' \
	'int          smod(int a, int b)                   { return a % b; }' \
	'unsigned int umod(unsigned int a, unsigned int b) { return a % b; }' \
	'int          sdiv(int a, int b)                   { return a / b; }' \
	'unsigned int udiv(unsigned int a, unsigned int b) { return a / b; }' \
	'int main(void) {' \
	'	return smod(351,151) + (int)umod(351u,151u)' \
	'	     + sdiv(351,151) + (int)udiv(351u,151u); /* = 102 */' \
	'}' \
	> $W/divmod.c
status=0; \
for opt in -O0 -O; do \
	obj="$W/divmod$opt.o"; \
	"$CC" $CPUFLAGS $opt -c -o "$obj" $W/divmod.c; \
	dis="$("$OBJDUMP" -d "$obj")"; \
	echo "==== $opt ===="; echo "$dis" | grep -Ew 'divsl|divul|divsll|divull' || true; \
	if ! printf '%s\n' "$dis" | grep -Ewq 'divsll|divull'; then \
		echo "FAIL$opt: no 32-bit-dividend divide (divsll/divull) emitted"; status=1; \
	fi; \
	if printf '%s\n' "$dis" | grep -Ewq 'divsl|divul'; then \
		echo "FAIL$opt: broken 64-bit-dividend form (divsl/divul) still emitted"; status=1; \
	fi; \
done; \
test $status -eq 0 && echo "test-divmod PASS: both registers preserved, no 64-bit-dividend form"
exit $status
