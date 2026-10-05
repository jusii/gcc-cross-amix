#!/bin/sh
# run.sh -- prove the 68060 multiply expansion computes what the hardware does.
#
#   sh tests/mul64/run.sh <amix-gcc> <workdir>
#
# Builds probe.c with the AMIX cross gcc twice per compile shape -- once as
# gcc emits it (AMIX_MUL64=keep, the 64-bit "mulu.l/muls.l <ea>,%dH:%dL" left
# in) and once with the expansion (the default) -- links each object into the
# Linux m68k harness and runs it under qemu-m68k on a 68020 and a 68060.
#
# Pass: for every shape, the original object traps on the 68060 (SIGILL: the
# 64-bit form is unimplemented there) and runs on the 68020, and the expanded
# object runs on both with the checksum of the original on the 68020.  All
# shapes also agree with each other, since they compile the same C.
#
# Needs qemu-m68k and a Linux m68k gcc (m68k-linux-gnu-gcc; override with
# LINUX_M68K_CC and QEMU_M68K).
set -e

CC=${1:?usage: run.sh <amix-gcc> <workdir>}
W=${2:?usage: run.sh <amix-gcc> <workdir>}
HERE=$(cd "$(dirname "$0")" && pwd)
LCC=${LINUX_M68K_CC:-m68k-linux-gnu-gcc}
QEMU=${QEMU_M68K:-qemu-m68k}

for t in "$LCC" "$QEMU"; do
	command -v "$t" >/dev/null 2>&1 || {
		echo "run.sh: $t not found (set LINUX_M68K_CC / QEMU_M68K)" >&2
		exit 1
	}
done

mkdir -p "$W"
"$LCC" -m68060 -O1 -c "$HERE/harness.c" -o "$W/harness.o"

status=0
ref=
for shape in "-O0" "-O" "-O2" "-O2 -fomit-frame-pointer" "-m68040 -O"; do
	tag=$(echo "$shape" | tr -d ' ' | tr -c 'A-Za-z0-9\n' _)
	for mode in keep expand; do
		obj="$W/probe$tag-$mode.o"
		AMIX_MUL64=$mode "$CC" $shape -c "$HERE/probe.c" -o "$obj"
		"$LCC" -m68060 -static -o "$W/run$tag-$mode" "$W/harness.o" "$obj"
	done
	k020=$("$QEMU" -cpu m68020 "$W/run$tag-keep" 2>&1) || k020="exit $?"
	if "$QEMU" -cpu m68060 "$W/run$tag-keep" > "$W/k060.out" 2>&1; then
		k060=$(cat "$W/k060.out")
	else
		k060="trap (exit $?)"
	fi
	e020=$("$QEMU" -cpu m68020 "$W/run$tag-expand" 2>&1) || e020="exit $?"
	e060=$("$QEMU" -cpu m68060 "$W/run$tag-expand" 2>&1) || e060="exit $?"
	printf '%-26s original 020: %s\n' "$shape" "$k020"
	printf '%-26s original 060: %s\n' "" "$k060"
	printf '%-26s expanded 020: %s\n' "" "$e020"
	printf '%-26s expanded 060: %s\n' "" "$e060"
	case "$k020" in "mul64 checksum "*) ;; *) echo "FAIL $shape: original object did not run on the 68020"; status=1 ;; esac
	case "$k060" in "trap "*) ;; *) echo "FAIL $shape: original object did not trap on the 68060 (does the probe still emit the 64-bit form?)"; status=1 ;; esac
	test "$e020" = "$k020" || { echo "FAIL $shape: expanded on 68020 differs from the original"; status=1; }
	test "$e060" = "$k020" || { echo "FAIL $shape: expanded on 68060 differs from the original"; status=1; }
	test -n "$ref" || ref=$k020
	test "$k020" = "$ref" || { echo "FAIL $shape: differs from the first shape ($ref)"; status=1; }
done
test $status -eq 0 && echo "test-mul64-run PASS: the expansion matches the 68020 and runs on the 68060"
exit $status
