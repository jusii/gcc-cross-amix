#!/bin/sh
# Regression test for the SGS compare-operand-order fixup as it applies to the
# 68881 "fcmp" (see fix_asm in amix-gcc-wrapper.sh).  config/m68k/sgs.h defines
# SGS_CMP_ORDER, so gcc prints both compare operands the other way round from
# what GNU as expects.  The wrapper swaps them back.  Two distinct failure modes
# hide behind this, and this target has to catch BOTH:
#
#   FP register vs memory  -- GNU as needs an FPU register as the DESTINATION,
#     so the SGS spelling is rejected outright and the build stops:
#       Error: operands mismatch -- statement `fcmp.d %fp0,16(%fp)' ignored
#
#   FP register vs FP register -- the reversed spelling is still VALID syntax,
#     so it assembles silently to a different encoding ("fcmp.x %fp2,%fp0" is
#     f200 0838, "fcmp.x %fp0,%fp2" is f200 0138).  FCMP computes destination
#     minus source, so the wrong order makes every following fbgt/fsgt test the
#     REVERSED relation, with no diagnostic anywhere.  Same severity class as
#     the tdivs defect: cross-built code that looks fine and computes garbage.
#
# Checking the sense mechanically, without being able to RUN the code, needs an
# invariant that does not depend on register allocation or stack offsets.  Each
# function below compares a MULTIPLY result against something else, C-source
# left-hand side first ("x > y" where x = a * b).  Because FCMP computes
# <second operand> minus <first operand>, a correctly ordered fcmp must name the
# register holding the multiply result as its SECOND operand.  So the invariant
# is simply: the destination of the fcmp is the register the fmul wrote.  That
# holds at -O0 (values reloaded from the stack) and at -O (values kept in FPU
# registers) alike, and it is exactly what breaks when the operands are reversed.
#
# Failure mode against a wrapper WITHOUT the fcmp half of the fixup (proof this
# test bites): rm_* fail to assemble with the "operands mismatch" above, and the
# rr_* pair assemble cleanly but report the fcmp destination as the fadd result
# rather than the fmul result -- a MISMATCH line and a non-zero exit.
. "$(dirname "$0")/lib.sh"
printf '%s\n' \
	'/* Every comparison puts a MULTIPLY result on the left of ">", so a' \
	'   correctly ordered fcmp must carry that register as its SECOND' \
	'   operand (FCMP computes second minus first).' \
	'   rr_* keep both values in FPU registers -> the SILENT failure shape.' \
	'   rm_* compare against a memory operand   -> the LOUD failure shape. */' \
	'int rr_d(double a, double b){ double x = a * b, y = a + b; return x > y; }' \
	'int rr_f(float  a, float  b){ float  x = a * b, y = a + b; return x > y; }' \
	'int rm_d(double a, double b){ double x = a * b;            return x > b; }' \
	'int rm_f(float  a, float  b){ float  x = a * b;            return x > b; }' \
	'int main(void) { return rr_d(3.0, 2.0) + rr_f(3.0f, 2.0f)' \
	'                      + rm_d(3.0, 2.0) + rm_f(3.0f, 2.0f); }' \
	> $W/fcmp.c
status=0; \
for opt in -O0 -O; do \
	obj="$W/fcmp$opt.o"; \
	"$CC" $CPUFLAGS $opt -c -o "$obj" $W/fcmp.c; \
	echo "==== $opt ===="; \
	"$OBJDUMP" -d "$obj" | awk ' \
		/^[0-9a-f]+ <.*>:/ { fn=$2; gsub(/[<>:]/,"",fn); mul=""; next } \
		/f(sgl)?mul[sdx]/  { n=split($0,p,","); mul=p[n]; sub(/[ \t]+$/,"",mul) } \
		/fcmp[sdx]/ { \
			n=split($0,p,","); d=p[n]; sub(/[ \t]+$/,"",d); \
			src=$0; sub(/.*fcmp[sdx][ \t]+/,"",src); sub(/,.*/,"",src); \
			if (mul == "" || d != mul) { \
				printf "  FAIL %s: fcmp destination %s is not the fmul result %s (comparison reversed)\n", fn, d, mul; bad=1 \
			} else { \
				printf "  ok   %s: fcmp %s,%s computes (fmul result %s) - src\n", fn, src, d, d \
			} \
			seen++ \
		} \
		END { \
			if (seen != 4) { printf "  FAIL: expected 4 fcmp sites, saw %d\n", seen; bad=1 } \
			exit bad ? 1 : 0 \
		}' || status=1; \
done; \
test $status -eq 0 && echo "test-fcmp PASS: compare operands in GNU order, branch sense matches the C source"
exit $status
