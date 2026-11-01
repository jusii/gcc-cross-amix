#!/bin/sh
# make test-uint64: a program using 64-bit integer arithmetic and the float to
# integer conversions compiles and links, every helper resolved from the
# installed libgcc.a.  The division, modulo and shift force __udivdi3,
# __umoddi3 and __lshrdi3; the conversions force __fixsfdi, __fixxfdi and
# __fixunsxfdi, which libgcc.a used to lack (the link failed).  Needs the AMIX
# crt objects and libc.so.1 in the sysroot, like test-hello.
. "$(dirname "$0")/lib.sh"
status=0
cat > "$W/uint64.c" <<'EOF'
unsigned long long udiv(unsigned long long a, unsigned long long b) { return a / b; }
unsigned long long umod(unsigned long long a, unsigned long long b) { return a % b; }
unsigned long long shr (unsigned long long a, int n)                { return a >> n; }
long long          f2ll  (float f)       { return f; }
long long          ld2ll (long double d) { return d; }
unsigned long long ld2ull(long double d) { return d; }
int main(void) {
	return (int)(udiv(1000000000000ULL, 7ULL) + umod(1000003ULL, 7ULL)
	           + shr((unsigned long long) 1 << 40, 8)
	           + f2ll(1.5f) + ld2ll(2.0L) + ld2ull(3.0L));
}
EOF
"$CC" $CPUFLAGS -o "$W/uint64" "$W/uint64.c"
for sym in __udivdi3 __umoddi3 __lshrdi3 __fixsfdi __fixxfdi __fixunsxfdi; do
	if "$NM" "$W/uint64" | grep -q " T $sym\$"; then
		echo "  ok   $sym linked from libgcc.a"
	else
		echo "  FAIL $sym is not defined in the executable"; status=1
	fi
done
test $status -eq 0 && echo "test-uint64 PASS: 64-bit arithmetic and float conversions link from libgcc.a"
exit $status
