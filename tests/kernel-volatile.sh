#!/bin/sh
# Regression test for AMIX_KERNEL_CFLAGS and the AMIX headers' "volatile".
#
# -traditional clears __STDC__, and the stock <sys/types.h> then does
# "#define volatile" and "#define const" (both empty) in its non-ANSI section.
# That strips the volatile from the "asm volatile" in <sys/inline.h>'s GNU spl
# primitives: each becomes a plain asm with an output, and gcc deletes it when
# the output is unused -- splx() always, and an spl6() whose result only feeds
# that splx().  The same macro erases every volatile on an MMIO access, so a
# 32-bit register poll is read once, as a byte, and the loop spins on a
# register.  -Dvolatile=__volatile__ -Dconst=__const__ define the names first,
# so the header's #ifndef guards skip the empty definitions.
#
# Checks, on a kernel-style unit compiled with the exact AMIX_KERNEL_CFLAGS:
#   (a) the preprocessor output has no empty "#define volatile"/"const";
#   (b) guard() writes %sr at least twice (the spl6 and the splx);
#   (c) pollbusy()'s loop re-reads the register with a 32-bit memory access
#       inside the loop, and never tests it with a byte-sized btst.
#
# Failure mode without the two -D flags (proof this test bites): (a) finds both
# empty defines, guard() has no %sr write at all, and pollbusy() tests
# "%a0@(19)" once with btst and then loops on "tstl %d0".  Reproduce with
#   make test-kernel-volatile AMIX_KERNEL_CFLAGS='-O -traditional -fno-builtin \
#     -Dinline=__inline__ $(CPUFLAGS) $(AMIX_KERNEL_CPPFLAGS) $(AMIX_KERNEL_INCLUDES)'
# Needs the AMIX headers: point AMIX_ROOT at a tree with usr/include/sys.
. "$(dirname "$0")/lib.sh"
test -f $AMIX_ROOT/usr/include/sys/inline.h || \
	{ echo "test-kernel-volatile: no usr/include/sys/inline.h under AMIX_ROOT=$AMIX_ROOT"; exit 1; }
printf '%s\n' \
	'#include <sys/types.h>' \
	'#include <sys/inline.h>' \
	'static volatile ulong_t *regs;' \
	'int guard(void) { int s; s = spl6(); /* critical section */ splx(s); return 0; }' \
	'void pollbusy(void) { while (*(volatile ulong_t *)(regs + 4) & 1) ; }' \
	> $W/kvolatile.c
"$CC" -c $AMIX_KERNEL_CFLAGS -o $W/kvolatile.o $W/kvolatile.c
status=0; \
defs="$("$CC" $AMIX_KERNEL_CFLAGS -dM -E $W/kvolatile.c)"; \
echo "==== -dM -E: volatile/const ===="; \
printf '%s\n' "$defs" | grep -E '^#define[[:space:]]+(volatile|const)([[:space:]]|$)' || true; \
if printf '%s\n' "$defs" | grep -Eq '^#define[[:space:]]+(volatile|const)[[:space:]]*$'; then \
	echo "  FAIL <sys/types.h> defines volatile/const away (empty #define)"; status=1; \
else \
	echo "  ok   no empty #define volatile/const"; \
fi; \
dis="$("$OBJDUMP" -d $W/kvolatile.o)"; \
guard="$(printf '%s\n' "$dis" | sed -n '/<guard>:$/,/^$/p')"; \
poll="$(printf '%s\n' "$dis" | sed -n '/<pollbusy>:$/,/^$/p')"; \
echo "==== guard ===="; printf '%s\n' "$guard"; \
echo "==== pollbusy ===="; printf '%s\n' "$poll"; \
srw=$(printf '%s\n' "$guard" | grep -Ec ',%sr[[:space:]]*$' || true); \
if [ "$srw" -ge 2 ]; then \
	echo "  ok   guard(): $srw %sr writes (spl6 and splx kept)"; \
else \
	echo "  FAIL guard(): $srw %sr writes, want >= 2 (spl6/splx deleted)"; status=1; \
fi; \
body="$(printf '%s\n' "$poll" | perl -ne '
	next unless /^\s*([0-9a-f]+):\t[0-9a-f ]+\t(.*)$/;
	push @l, [hex $1, $2];
	END { for my $i (0..$#l) {
		my ($a, $t) = @{$l[$i]};
		next unless $t =~ /^(b[a-z]+|db[a-z]+)\b.*?([0-9a-f]+) </;
		my $to = hex $2; next unless $to <= $a;
		print map { "$_->[1]\n" } grep { $_->[0] >= $to && $_->[0] <= $a } @l; last; } }')"; \
if [ -z "$body" ]; then \
	echo "  FAIL pollbusy(): no backward branch, no poll loop found"; status=1; \
elif printf '%s\n' "$body" | grep -Eq '^(movel|andl|tstl|cmpl)[[:space:]].*%a[0-7]@'; then \
	echo "  ok   pollbusy(): the loop re-reads the register (32-bit memory access)"; \
else \
	echo "  FAIL pollbusy(): the loop body has no memory read (read hoisted):"; \
	printf '%s\n' "$body" | sed 's/^/         /'; status=1; \
fi; \
if printf '%s\n' "$poll" | grep -Eq 'btst[[:space:]].*%a[0-7]@'; then \
	echo "  FAIL pollbusy(): a byte-sized btst on the 32-bit register"; status=1; \
else \
	echo "  ok   pollbusy(): no byte access to the 32-bit register"; \
fi; \
test $status -eq 0 && echo "test-kernel-volatile PASS: spl masks and MMIO volatile survive AMIX_KERNEL_CFLAGS"
exit $status
