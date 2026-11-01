#!/bin/sh
# make test-options: options reach the tool they belong to.
#
# The wrapper used to send every option it did not recognise to ld: -ansi was
# an ld error, -include was dropped, -Wl,-Map,<file> wrote no map, -M printed
# an ld map, -dumpversion linked a program, and "gcc -c foo.c bar.s" exited 0
# without bar.o.  Linker options are now an explicit list and every other
# option goes to the compiler.  Each case below checks the files and output
# produced, not only the exit status.  Links need the AMIX crt objects and
# libc.so.1 in the sysroot.
. "$(dirname "$0")/lib.sh"
status=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; status=1; }
cd "$W"
rm -f ./*.o ./*.map ./a.out ./prog* ./*.err
cat > prog.c <<'EOF'
#ifndef FROM_INCLUDE
#error -include did not reach the compiler
#endif
int main(void) { return 0; }
EOF
printf '#define FROM_INCLUDE 1\n' > inc.h
printf 'int helper(void) { return 1; }\n' > helper.c
printf '\t.text\n\t.globl\tasmfn\nasmfn:\n\trts\n' > asmfn.s

"$CC" $CPUFLAGS -ansi -include inc.h -o prog1 prog.c && test -f prog1 &&
	ok "-ansi and -include go to the compiler in a link" || bad "-ansi/-include in a link"
"$CC" $CPUFLAGS -include inc.h -Wl,-Map,prog2.map -o prog2 prog.c && test -s prog2.map &&
	ok "-Wl,-Map,prog2.map writes the map" || bad "-Wl,-Map wrote no map"
"$CC" $CPUFLAGS -include inc.h -Xlinker -Map -Xlinker prog3.map -o prog3 prog.c && test -s prog3.map &&
	ok "-Xlinker -Map -Xlinker prog3.map writes the map" || bad "-Xlinker wrote no map"
deps=$("$CC" $CPUFLAGS -M -include inc.h prog.c) && case "$deps" in prog.o:*) true ;; *) false ;; esac &&
	test ! -f a.out && ok "-M prints the dependency rule and links nothing" || bad "-M: '$deps'"
v=$("$CC" -dumpversion) && test "$v" = 2.7.2.3 && test ! -f a.out &&
	ok "-dumpversion prints $v and links nothing" || bad "-dumpversion: '$v'"
lg=$("$CC" -print-libgcc-file-name) && test -f "$lg" &&
	ok "-print-libgcc-file-name names an existing libgcc.a" || bad "-print-libgcc-file-name: '$lg'"
"$CC" $CPUFLAGS -c helper.c asmfn.s && test -f helper.o && test -f asmfn.o &&
	ok "-c helper.c asmfn.s writes both objects" || bad "-c with a .c and a .s"
cp prog.c prog.txt
"$CC" $CPUFLAGS -include inc.h -x c prog.txt -o prog4 && test -f prog4 &&
	ok "-x c in a link compiles a file of any suffix" || bad "-x c in a link"
if "$CC" $CPUFLAGS -o prog5 prog.c -o 2> o.err; then bad "a trailing -o with no file was accepted"
else grep -q -- '-o needs an argument' o.err && ok "a trailing -o is an error" || bad "trailing -o: $(cat o.err)"; fi
if "$CC" $CPUFLAGS -include inc.h -fno-such-option -o prog6 prog.c 2> f.err; then bad "an unknown -f option was accepted"
else grep -q 'cc1' f.err && ok "an unknown option is reported by the compiler, not ld" || bad "unknown option: $(cat f.err)"; fi
"$CC" $CPUFLAGS -nostdlib -Wl,-e,helper -o prog7 helper.c && test -f prog7 &&
	! "$OBJDUMP" -p prog7 | grep -q NEEDED && ! "$NM" prog7 | grep -q ' _start$' &&
	ok "-nostdlib links no startup objects and no libc" || bad "-nostdlib"
"$CC" $CPUFLAGS -v -include inc.h -o prog8 prog.c 2> v.err && grep -q -- '-ld -o prog8' v.err &&
	ok "-v shows the ld command" || bad "-v did not show the link"

test $status -eq 0 && echo "test-options PASS: linker options to ld, compiler options to the compiler, queries answered"
exit $status
