#!/bin/sh
# make test-lcomm: local common data keeps the alignment the source asked for.
#
# GNU as 2.8.1 takes ".lcomm name,size" only and aligns by size (at most 8),
# so fix_asm drops the alignment gcc appends.  That loses nothing for ordinary
# data, but used to drop an __attribute__((aligned(N))) above it silently.
# Checks, on the object:
#   (a) over-aligned statics (16 and 32 on a 3-byte and a 4-byte object, 8 on
#       a 2-byte one) sit at addresses that are multiples of what was asked;
#   (b) ordinary statics still come out of the two-operand .lcomm, at their
#       size alignment, in .bss, and the -S output has no 3-operand .lcomm.
. "$(dirname "$0")/lib.sh"
status=0
cd "$W"
cat > lcomm.c <<'EOF2'
static char a16[3] __attribute__((aligned(16)));
static int i32 __attribute__((aligned(32)));
static short s8 __attribute__((aligned(8)));
static char c1;
static int plain[10];
static double d;
char *use(void) { c1 = 1; plain[1] = 2; d = 3.0; s8 = 4; i32 = 5; return a16; }
EOF2
"$CC" $CPUFLAGS -O -S lcomm.c -o lcomm.s
"$CC" $CPUFLAGS -O -c lcomm.c -o lcomm.o
if grep -Eq '^[[:space:]]*\.lcomm[[:space:]]+[^,]+,[^,]+,' lcomm.s; then
	echo "  FAIL a three-operand .lcomm reached the assembler"; status=1
fi
"$OBJDUMP" -t lcomm.o > lcomm.sym
for e in a16:16 i32:32 s8:8 c1:1 plain:4 d:8; do
	n=${e%%:*} al=${e#*:}
	line=$(awk -v n="$n" '$NF == n' lcomm.sym)
	addr=$(echo "$line" | awk '{print $1}')
	case "$line" in *.bss*) ;; *) echo "  FAIL $n is not in .bss: $line"; status=1; continue ;; esac
	if test -n "$addr" && test $((0x$addr % al)) -eq 0; then
		echo "  ok   $n at .bss+0x$addr, aligned to $al"
	else
		echo "  FAIL $n at .bss+0x$addr is not aligned to $al"; status=1
	fi
done
test $status -eq 0 && echo "test-lcomm PASS: aligned(N) honoured in .bss, ordinary statics unchanged"
exit $status
