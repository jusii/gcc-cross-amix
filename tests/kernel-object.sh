#!/bin/sh
# make test-kernel-object: stock AMIX kernel drivers compile with
# AMIX_KERNEL_CFLAGS into the objects the native compiler made.
#
# The AMIX tree ships each driver's source next to the object the native SGS
# toolchain built from it (usr/sys/amiga/driver/*.c and *.o).  For every driver
# below the cross object must
#   (a) be an ELF relocatable for the m68k (e_type 1, e_machine 4);
#   (b) define exactly the global text, data and bss symbols the native
#       object defines -- a function or table lost on the way (a truncated
#       assembly file, a scrubbed line) shows up here; and
#   (c) pass the 68060 scanner.
# The encodings themselves differ from the native ones (another assembler), so
# the objects are not compared byte for byte.  Needs AMIX_ROOT.
. "$(dirname "$0")/lib.sh"
D=$AMIX_ROOT/usr/sys/amiga/driver
test -d "$D" || { echo "test-kernel-object: no usr/sys/amiga/driver under AMIX_ROOT=$AMIX_ROOT" >&2; exit 1; }
status=0
n=0
for drv in amiga bb ben dummy machid ql ram slip tiga; do
	test -f "$D/$drv.c" && test -f "$D/$drv.o" || { echo "  skip $drv (no $drv.c and $drv.o in the tree)"; continue; }
	o=$W/$drv.o
	if ! "$CC" $AMIX_KERNEL_CFLAGS -c "$D/$drv.c" -o "$o"; then
		echo "  FAIL $drv.c does not compile"; status=1; continue
	fi
	n=$((n + 1))
	hdr=$(od -An -tx1 -j16 -N4 "$o" | tr -d ' \n')
	test "$hdr" = 00010004 || { echo "  FAIL $drv.o is not an m68k ELF relocatable (type/machine $hdr)"; status=1; }
	"$NM" "$D/$drv.o" | awk '$2 ~ /^[TDBR]$/ { print $3 }' | sort > "$W/$drv.native"
	"$NM" "$o" | awk '$2 ~ /^[TDBR]$/ { print $3 }' | sort > "$W/$drv.cross"
	if cmp -s "$W/$drv.native" "$W/$drv.cross"; then
		echo "  ok   $drv: the $(wc -l < "$W/$drv.cross") global symbols of the native object"
	else
		echo "  FAIL $drv: global symbols differ from the native object:"
		diff "$W/$drv.native" "$W/$drv.cross" | sed 's/^/         /'
		status=1
	fi
	"$SCAN060" --quiet "$o" || { echo "  FAIL $drv.o: 68060-unimplemented instruction"; status=1; }
done
test $n -gt 0 || { echo "  FAIL no driver compiled"; status=1; }
test $status -eq 0 && echo "test-kernel-object PASS: $n stock drivers, native symbol sets, 68060-clean"
exit $status
