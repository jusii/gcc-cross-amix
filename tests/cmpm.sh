#!/bin/sh
# make test-cmpm: every spelling of a compare gets the GNU operand order.
#
# cc1 prints CMPA, CMPI and CMPM as "cmp" (sgs.h), also at the start of an
# inline asm line, and fix_asm rule 6 swaps "cmp.[bwl]" back to GNU order.  An
# inline asm line that starts with white space keeps the spelled-out mnemonic,
# and rule 6 did not match it: "\tcmpm.l (%1)+,(%2)+" assembled with the
# operands reversed while "cmpm.l (%1)+,(%2)+" did not.  Each function below
# has the same compares, once at the start of the template and once after a
# tab; the two must assemble to the same instructions, and the inline asm,
# written in this target's SGS order, must come out as the C reads it.
. "$(dirname "$0")/lib.sh"
status=0
cd "$W"
cat > cmpm.c <<'EOF2'
int m0(char *p, char *q) { int r; __asm__("cmpm.b (%1)+,(%2)+\n\tseq %0" : "=d"(r), "=a"(p), "=a"(q) : "1"(p), "2"(q)); return r; }
int m1(char *p, char *q) { int r; __asm__("\tcmpm.b (%1)+,(%2)+\n\tseq %0" : "=d"(r), "=a"(p), "=a"(q) : "1"(p), "2"(q)); return r; }
int a0(char *p, char *q) { int r; __asm__("cmpa.l %1,%2\n\tseq %0" : "=d"(r) : "a"(p), "a"(q)); return r; }
int a1(char *p, char *q) { int r; __asm__("\tcmpa.l %1,%2\n\tseq %0" : "=d"(r) : "a"(p), "a"(q)); return r; }
int i0(int x) { int r; __asm__("cmpi.l %1,&5\n\tseq %0" : "=d"(r) : "d"(x)); return r; }
int i1(int x) { int r; __asm__("\tcmpi.l %1,&5\n\tseq %0" : "=d"(r) : "d"(x)); return r; }
EOF2
"$CC" $CPUFLAGS -O -c cmpm.c -o cmpm.o
"$OBJDUMP" -d cmpm.o > cmpm.dis
for f in m a i; do
	sed -n "/<${f}0>:\$/,/^\$/p" cmpm.dis | sed '1d' | cut -f3 | grep . > $f.0
	sed -n "/<${f}1>:\$/,/^\$/p" cmpm.dis | sed '1d' | cut -f3 | grep . > $f.1
	if test -s $f.0 && cmp -s $f.0 $f.1; then
		echo "  ok   cmp${f}: the same instructions with and without the leading tab: $(grep cmp $f.0)"
	else
		echo "  FAIL cmp${f}: the two spellings assemble differently:"; paste $f.0 $f.1 | sed 's/^/         /'; status=1
	fi
done
# SGS order is <first>,<second> = compare <second> against <first>... as gcc
# itself emits it; in GNU order the operands come out exchanged.
grep -q 'cmpmb %a1@+,%a0@+\|cmpmb %a0@+,%a1@+' m.0 || { echo "  FAIL no cmpm.b decoded"; status=1; }
test $status -eq 0 && echo "test-cmpm PASS: cmpm, cmpa and cmpi get rule 6 however the inline asm is indented"
exit $status
