#!/bin/sh
# make test-asopts: assembler options that take a value reach GNU as with it.
#
# The assembler wrapper the driver runs read every word that did not start
# with '-' as an input file, so "-Wa,--defsym,SYM=1" or "-Wa,-I,dir" failed
# with "more than one input (SYM=1, foo.s)".  It now parses options the way
# GNU as 2.8.1 does: -I -o -A -m -Q and --defsym --emulation --itbl take a
# value, attached or as the next word, and long options may be written with
# one dash or abbreviated.  Each case checks that the value took effect: the
# symbol's value assembled into the object, the included file's symbol
# defined.  Two real inputs must still be refused.
. "$(dirname "$0")/lib.sh"
status=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; status=1; }
cd "${W:?}"
rm -rf ./*.o ./*.err ./*.lst ./incdir
mkdir incdir
cat > t.s <<'EOF'
	.include "inc.s"
	.data
	.globl	defval
defval:
	.long	X
	.ifdef	X
	.globl	defsym_seen
defsym_seen:
	.long	0
	.endif
EOF
printf '\t.text\n\t.globl\tfrom_include\nfrom_include:\n\trts\n' > incdir/inc.s
printf 'int helper(void) { return 1; }\n' > helper.c
printf '\t.text\n\t.globl\tother\nother:\n\trts\n' > other.s

# check OBJECT VALUE: defval holds VALUE, defsym_seen and from_include defined
check()
{
	test -f "$1" || return 1
	"$NM" "$1" > "$1.nm" || return 1
	grep -q ' T from_include$' "$1.nm" && grep -q ' D defsym_seen$' "$1.nm" || return 1
	v=$("$OBJDUMP" -s -j .data "$1" | awk '$1 == "0000" { print $2; exit }')
	test "$v" = "$2"
}

"$CC" $CPUFLAGS -Wa,--defsym,X=1 -Wa,-I,incdir -c t.s -o sep.o && check sep.o 00000001 &&
	ok "-Wa,--defsym,X=1 -Wa,-I,incdir: value and include take effect" || bad "--defsym and -I with separate values"
"$CC" $CPUFLAGS -Wa,--defsym=X=0x2a -Wa,-Iincdir -c t.s -o eq.o && check eq.o 0000002a &&
	ok "-Wa,--defsym=X=0x2a -Wa,-Iincdir: the attached spellings" || bad "--defsym= and -Idir"
"$CC" $CPUFLAGS -Wa,-defsym,X=3 -Wa,--def,Y=4 -Wa,-I,incdir -c t.s -o abbr.o && check abbr.o 00000003 &&
	ok "-Wa,-defsym and an abbreviated --def, as GNU as reads them" || bad "one-dash or abbreviated --defsym"
"$CC" $CPUFLAGS -Wa,-I,incdir -Wa,-L,--defsym,X=5 -c t.s -o mixed.o && check mixed.o 00000005 &&
	ok "a value option after a flag in one -Wa list" || bad "-Wa,-L,--defsym,X=5"
"$CC" $CPUFLAGS -Wa,--defsym,X=1 -Wa,-I,incdir -Wa,-al=t.lst -c t.s -o lst.o && check lst.o 00000001 &&
	grep -q defsym_seen t.lst && ok "-Wa,-al=t.lst: -a takes only an attached value" || bad "-a listing"
"$CC" $CPUFLAGS -m68040 -Wa,--defsym,X=1 -Wa,-I,incdir -c t.s -o m40.o &&
	"$CC" $CPUFLAGS -m68040 -Wa,--defsym=X=1 -Wa,-Iincdir -c t.s -o m40eq.o && cmp -s m40.o m40eq.o && check m40.o 00000001 &&
	ok "-m68040 with separate values: the same object as the attached spellings" || bad "-m68040 with --defsym"
"$CC" $CPUFLAGS -O -Wa,--defsym,X=7 -c helper.c -o helper.o && "$CC" $CPUFLAGS -O -c helper.c -o helper0.o &&
	"$NM" helper.o | grep -q '^00000007 a X$' &&
	test "$("$OBJDUMP" -d helper.o | sed 1,2d)" = "$("$OBJDUMP" -d helper0.o | sed 1,2d)" &&
	ok "a C compile with -Wa,--defsym,X=7: X defined, the code unchanged" || bad "C compile with --defsym"

if "$CC" $CPUFLAGS -Wa,-I,incdir -c t.s -Wa,other.s -o two.o 2> two.err; then bad "two inputs were accepted"
else grep -q 'more than one input (other.s, t.s)' two.err && ok "two real inputs are refused: $(head -n 1 two.err)" ||
	bad "two inputs: $(cat two.err)"; fi
test ! -f two.o || bad "two inputs left an object"
# the driver puts -Wa options before -o, so a value-less option at the end of
# the line can only be written to the assembler wrapper itself
AS=$("$CC" -print-prog-name=as)
for o in -I --defsym; do
	if "$AS" -o noval.o t.s $o 2> noval.err; then bad "$o with no value was accepted"
	else grep -q -- "$o needs an argument" noval.err && ok "$o with no value is an error" ||
		bad "$o with no value: $(cat noval.err)"; fi
done

test $status -eq 0 && echo "test-asopts PASS: assembler options keep their values; two inputs refused"
exit $status
