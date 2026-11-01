#!/bin/sh
# make test-link: a link finds what the native cc finds and starts the same way.
#
#   (a) -lm resolves: libm.a is in usr/ccs/lib, which the wrapper did not
#       search ("cannot resolve -lm"); now it searches usr/lib, then
#       usr/ccs/lib, and sqrt comes from libm.a, with the _fpsetround it
#       needs from the static part of libc (usr/ccs/lib/libc.so), while the
#       program still depends on /usr/lib/libc.so.1;
#   (b) values-X?.o is linked after crti.o by the native rule -- values-Xc.o
#       with -ansi, values-Xt.o with -traditional, values-Xa.o otherwise --
#       and _lib_version is defined in the program (it was left out, so every
#       program ran as c_issue_4);
#   (c) -nostartfiles leaves it out with the crt objects.
# Needs the AMIX crt objects, values-X*.o, libc.so.1 and libm.a in the sysroot.
. "$(dirname "$0")/lib.sh"
status=0
cd "$W"
rm -f ./prog* ./*.err
cat > m.c <<'EOF2'
extern double sqrt();
int main() { return (int) sqrt(16.0); }
EOF2
if "$CC" $CPUFLAGS -o prog-m m.c -lm 2> m.err && "$NM" prog-m | grep -q ' T sqrt$' &&
	"$NM" prog-m | grep -q ' T _fpsetround$' && "$OBJDUMP" -p prog-m | grep -q 'NEEDED.*/usr/lib/libc.so.1'; then
	echo "  ok   -lm resolves from usr/ccs/lib/libm.a"
else
	echo "  FAIL -lm: $(cat m.err)"; status=1
fi
for case in "values-Xa.o:" "values-Xt.o:-traditional" "values-Xc.o:-ansi" "values-Xc.o:-traditional -ansi"; do
	want=${case%%:*} flags=${case#*:}
	"$CC" $CPUFLAGS $flags -v -o prog-v m.c -lm 2> v.err
	line=$(grep -- '-ld -o prog-v' v.err)
	case "$line" in
		*"crti.o "*"/$want "*)
			if "$NM" prog-v | grep -q ' _lib_version$'; then
				echo "  ok   ${flags:-(no flag)}: $want linked, _lib_version defined"
			else
				echo "  FAIL ${flags:-(no flag)}: no _lib_version in the program"; status=1
			fi ;;
		*) echo "  FAIL ${flags:-(no flag)}: $want not linked after crti.o: $line"; status=1 ;;
	esac
done
"$CC" $CPUFLAGS -nostartfiles -v -Wl,-e,main -o prog-ns m.c -lm 2> ns.err
if grep -- '-ld -o prog-ns' ns.err | grep -q 'values-X\|crt1.o'; then
	echo "  FAIL -nostartfiles still links startup objects"; status=1
else
	echo "  ok   -nostartfiles links no crt or values-X object"
fi
test $status -eq 0 && echo "test-link PASS: usr/ccs/lib searched, values-X?.o by the native rule"
exit $status
