#!/bin/sh
# Regression test for AMIX_USER_CFLAGS: the same <sys/types.h> trap as above,
# for user programs.  -traditional clears __STDC__, so every user unit that
# includes <sys/types.h> (directly or through most system headers) had
# "volatile" and "const" defined away: a poll through a volatile pointer is
# read once, as a byte, and the loop spins on a register, and const tables land
# in writable .data.  The flags carry -Dvolatile=__volatile__
# -Dconst=__const__, as AMIX_KERNEL_CFLAGS does.
#
# Checks, on a user unit compiled with the exact AMIX_USER_CFLAGS:
#   (a) the preprocessor output has no empty "#define volatile"/"const";
#   (b) pollreg()'s loop re-reads *reg with a 32-bit memory access inside the
#       loop, and never tests it with a byte-sized btst;
#   (c) the const table is read-only data (nm type r), not .data.
#
# Failure mode without the two -D flags (proof this test bites): (a) finds both
# empty defines, pollreg() tests "%a0@(3)" once with btst and then loops on
# "tstl %d0", and the table is nm type d.  Reproduce with
#   make test-user-volatile AMIX_USER_CFLAGS='-O -traditional -fno-builtin \
#     $(CPUFLAGS) -I$(SYSROOT)/usr/include'
. "$(dirname "$0")/lib.sh"
test -f $SYSROOT/usr/include/sys/types.h || \
	{ echo "test-user-volatile: no usr/include/sys/types.h under SYSROOT=$SYSROOT"; exit 1; }
printf '%s\n' \
	'#include <sys/types.h>' \
	'static const int table[4] = { 1, 2, 3, 4 };' \
	'int lookup(int i) { return table[i & 3]; }' \
	'void pollreg(volatile ulong_t *reg) { while (*reg & 1) ; }' \
	> $W/uvolatile.c
AMIX_SYSROOT="$SYSROOT" "$CC" -c $AMIX_USER_CFLAGS -o $W/uvolatile.o $W/uvolatile.c
status=0; \
defs="$(AMIX_SYSROOT="$SYSROOT" "$CC" $AMIX_USER_CFLAGS -dM -E $W/uvolatile.c)"; \
echo "==== -dM -E: volatile/const ===="; \
printf '%s\n' "$defs" | grep -E '^#define[[:space:]]+(volatile|const)([[:space:]]|$)' || true; \
if printf '%s\n' "$defs" | grep -Eq '^#define[[:space:]]+(volatile|const)[[:space:]]*$'; then \
	echo "  FAIL <sys/types.h> defines volatile/const away (empty #define)"; status=1; \
else \
	echo "  ok   no empty #define volatile/const"; \
fi; \
dis="$("$OBJDUMP" -d $W/uvolatile.o)"; \
poll="$(printf '%s\n' "$dis" | sed -n '/<pollreg>:$/,/^$/p')"; \
echo "==== pollreg ===="; printf '%s\n' "$poll"; \
body="$(printf '%s\n' "$poll" | perl -ne '
	next unless /^\s*([0-9a-f]+):\t[0-9a-f ]+\t(.*)$/;
	push @l, [hex $1, $2];
	END { for my $i (0..$#l) {
		my ($a, $t) = @{$l[$i]};
		next unless $t =~ /^(b[a-z]+|db[a-z]+)\b.*?([0-9a-f]+) </;
		my $to = hex $2; next unless $to <= $a;
		print map { "$_->[1]\n" } grep { $_->[0] >= $to && $_->[0] <= $a } @l; last; } }')"; \
if [ -z "$body" ]; then \
	echo "  FAIL pollreg(): no backward branch, no poll loop found"; status=1; \
elif printf '%s\n' "$body" | grep -Eq '^(movel|andl|tstl|cmpl)[[:space:]].*%a[0-7]@'; then \
	echo "  ok   pollreg(): the loop re-reads the register (32-bit memory access)"; \
else \
	echo "  FAIL pollreg(): the loop body has no memory read (read hoisted):"; \
	printf '%s\n' "$body" | sed 's/^/         /'; status=1; \
fi; \
if printf '%s\n' "$poll" | grep -Eq 'btst[[:space:]].*%a[0-7]@'; then \
	echo "  FAIL pollreg(): a byte-sized btst on the 32-bit register"; status=1; \
else \
	echo "  ok   pollreg(): no byte access to the 32-bit register"; \
fi; \
tbl="$("$NM" $W/uvolatile.o | awk '$3 == "table" { print $2 }')"; \
if [ "$tbl" = r ]; then \
	echo "  ok   const table is read-only data (nm type r)"; \
else \
	echo "  FAIL const table has nm type '$tbl', want r (const dropped)"; status=1; \
fi; \
test $status -eq 0 && echo "test-user-volatile PASS: volatile polls and const data survive AMIX_USER_CFLAGS"
exit $status
