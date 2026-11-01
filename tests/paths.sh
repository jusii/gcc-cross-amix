#!/bin/sh
# make test-paths: every way of compiling gets the assembler repairs.
#
# Only "-c foo.c" and compile-and-link used to run fix_asm.  "gcc -E foo.c >
# foo.i; gcc -c foo.i" (ccache, distcc, creduce) went straight from cc1 to GNU
# as and produced a reversed compare ("cmpl %d1,%d0", b081) and the 64-bit-
# dividend divide (divsl, 4c41 2c00) with no diagnostic; "-S" wrote raw SGS
# assembly, and assembling it moved every switch table by 4 bytes.  Now the real
# driver assembles everything through the assembler wrapper.
#
# The probe has a switch (rule 1), a variable divide (rule 2) and integer and
# FP compares (rule 6).  Each route below must give the object "-c foo.c"
# gives, byte for byte:
#   .i from -E, compiled with -c; -S then -c on the .s; -S then the bare GNU
#   as; -pipe; -save-temps; "-x c" on a file with another suffix; and the .i
#   and the -S output linked into a program next to main.c, against the
#   same program built from foo.c.
# A hand-written .s in GNU operand order must come out of "gcc -c" exactly as
# the bare assembler makes it (it carries no compiler .ident, so the wrapper
# leaves it alone), and "-S -o -" must still print the compiler's .ident line.
. "$(dirname "$0")/lib.sh"
status=0
AS=$TOOL-as
asarch=-m68020
for f in $CPUFLAGS; do case "$f" in -m68030|-m68040|-m68060) asarch=$f ;; esac; done
cd "$W"
rm -f ./*.o ./*.i ./*.s ./*.dis ./paths ./paths-*
cat > probe.c <<'EOF'
int sw(int x) { switch (x) { case 0: return 3; case 1: return 9; case 2: return 11; case 3: return 17; } return 0; }
int dv(int a, int b) { return a / b + a % b; }
int lt(int a, int b) { return a < b; }
int fgt(double a, double b) { double x = a * b, y = a + b; return x > y; }
EOF
cat > main.c <<'EOF'
extern int sw(), dv(), lt(), fgt();
int main(void) { return sw(2) + dv(351, 151) + lt(1, 2) + fgt(3.0, 2.0); }
EOF
same() { # same <what> <object>
	if cmp -s ref.o "$2"; then echo "  ok   $1: same object as -c probe.c"
	else echo "  FAIL $1: object differs from -c probe.c"; status=1; fi
}
"$CC" $CPUFLAGS -O -c probe.c -o ref.o
"$OBJDUMP" -d ref.o | grep -q divsll || { echo "  FAIL the reference has no divsll (rule 2 not applied)"; status=1; }

"$CC" $CPUFLAGS -O -E probe.c > probe.i
"$CC" $CPUFLAGS -O -c probe.i -o i.o && same ".i input" i.o

"$CC" $CPUFLAGS -O -S probe.c -o s.s
"$CC" $CPUFLAGS -c s.s -o s.o && same "-S then -c" s.o
"$AS" $asarch -o s-as.o s.s && same "-S then bare GNU as" s-as.o
"$CC" $CPUFLAGS -O -S probe.c -o s2.s
"$CC" $CPUFLAGS -c s2.s -o s2.o && cmp -s s.o s2.o && "$CC" $CPUFLAGS -c s.s -o s3.o && cmp -s s.o s3.o ||
	{ echo "  FAIL assembling -S output twice is not stable"; status=1; }
grep -q '^| amix fix_asm$' s.s || { echo "  FAIL -S output carries no fix_asm marker"; status=1; }

"$CC" $CPUFLAGS -O -pipe -c probe.c -o pipe.o && same "-pipe" pipe.o
mkdir -p st && ( cd st && "$CC" $CPUFLAGS -O -save-temps -c ../probe.c -o ../st.o ) && same "-save-temps" st.o
cp probe.c probe.txt
"$CC" $CPUFLAGS -O -x c -c probe.txt -o x.o
# the object names its source file, probe.txt here, so compare the code
"$OBJDUMP" -d ref.o | sed '1,/^Disassembly/d' > ref.dis
"$OBJDUMP" -d x.o | sed '1,/^Disassembly/d' > x.dis
if cmp -s ref.dis x.dis; then echo "  ok   -x c: same code as -c probe.c"
else echo "  FAIL -x c: code differs from -c probe.c"; status=1; fi

"$CC" $CPUFLAGS -O -o paths-ref main.c probe.c
"$CC" $CPUFLAGS -O -o paths-i main.c probe.i
"$CC" $CPUFLAGS -O -o paths-s main.c s.s
for p in paths-i paths-s; do
	if cmp -s paths-ref $p; then echo "  ok   link with ${p#paths-} input: same program as with probe.c"
	else echo "  FAIL link with ${p#paths-} input: program differs"; status=1; fi
done

cat > hand.s <<'EOF'
| hand-written, GNU operand order: compare %d1 with %d0
	.text
	.globl	hand
hand:
	cmp.l	%d1,%d0
	rts
EOF
"$CC" $CPUFLAGS -c hand.s -o hand.o
"$AS" $asarch -o hand-as.o hand.s
if cmp -s hand.o hand-as.o; then echo "  ok   hand-written .s assembled as written"
else echo "  FAIL gcc -c changed a hand-written .s"; status=1; fi

"$CC" $CPUFLAGS -S -o - probe.c | grep -q '\.ident.*"GCC: (GNU) ' ||
	{ echo "  FAIL -S -o - does not print the compiler's .ident"; status=1; }

left=$(ls "$TMPDIR" | wc -l)
test "$left" -eq 0 && echo "  ok   no temporary file left behind" ||
	{ echo "  FAIL $left temporary files left in $TMPDIR"; ls "$TMPDIR" | sed 's/^/         /'; status=1; }

test $status -eq 0 && echo "test-paths PASS: .i, -S, -pipe, -save-temps, -x and links all get the repairs; .s left alone"
exit $status
