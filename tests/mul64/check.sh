#!/bin/sh
# check.sh -- encoding gate for the 68060 multiply expansion (make test-mul64).
#
#   sh tests/mul64/check.sh <amix-gcc> <workdir>
#
# Needs only the installed wrapper and its scanner (<amix-gcc> with "-gcc"
# replaced by "-scan060").  The results are proven separately under qemu by
# run.sh (make test-mul64-run).
set -e

CC=${1:?usage: check.sh <amix-gcc> <workdir>}
W=${2:?usage: check.sh <amix-gcc> <workdir>}
HERE=$(cd "$(dirname "$0")" && pwd)
SCAN=${CC%-gcc}-scan060
mkdir -p "$W"
status=0
fail() { echo "FAIL: $*"; status=1; }

# 1. every shape: expanded by default, the 64-bit form kept on request
for shape in "-O0" "-O" "-O2" "-m68040 -O"; do
	tag=$(echo "$shape" | tr -d ' ' | tr -c 'A-Za-z0-9\n' _)
	"$CC" $shape -c "$HERE/probe.c" -o "$W/p$tag.o"
	AMIX_MUL64=keep "$CC" $shape -c "$HERE/probe.c" -o "$W/p$tag-keep.o"
	"$CC" -mmul64 $shape -c "$HERE/probe.c" -o "$W/p$tag-flag.o"
	AMIX_MUL64=keep "$CC" -mno-mul64 $shape -c "$HERE/probe.c" -o "$W/p$tag-noflag.o"
	if "$SCAN" "$W/p$tag.o"; then :; else fail "$shape: 68060-unimplemented instruction left"; fi
	if "$SCAN" --quiet "$W/p$tag-keep.o" > "$W/keep.scan"; then
		fail "$shape: AMIX_MUL64=keep object has no 64-bit multiply (the probe no longer bites)"
	fi
	grep -q '64-bit product' "$W/keep.scan" || fail "$shape: no 64-bit product in the kept object"
	cmp -s "$W/p$tag-keep.o" "$W/p$tag-flag.o" || fail "$shape: -mmul64 differs from AMIX_MUL64=keep"
	cmp -s "$W/p$tag.o" "$W/p$tag-noflag.o" || fail "$shape: -mno-mul64 does not override AMIX_MUL64=keep"
done

# 2. code without the 64-bit form is byte-identical either way
cat > "$W/plain.c" <<'EOF'
int smod(int a, int b) { return a % b; }
unsigned udiv(unsigned a, unsigned b) { return a / b; }
int mul(int a, int b) { return a * b; }
int sh(int a) { return a / 8 + (a << 3); }
int sw(int x) { switch (x) { case 0: return 3; case 1: return 9; case 2: return 11; case 3: return 17; } return 0; }
EOF
for opt in -O0 -O; do
	"$CC" $opt -c "$W/plain.c" -o "$W/plain$opt.o"
	AMIX_MUL64=keep "$CC" $opt -c "$W/plain.c" -o "$W/plain$opt-keep.o"
	cmp -s "$W/plain$opt.o" "$W/plain$opt-keep.o" || fail "$opt: an object without a 64-bit multiply changed"
done

# 3. a leftover 64-bit form fails the compile, unless kept
cat > "$W/div64.c" <<'EOF'
int q(int hi, int lo, int d) { __asm__("divs.l %2,%0:%1" : "=d"(hi), "=d"(lo) : "d"(d), "0"(hi), "1"(lo)); return lo; }
EOF
rm -f "$W/div64.o"
if "$CC" -O -c "$W/div64.c" -o "$W/div64.o" 2> "$W/div64.err"; then
	fail "a 64-bit-dividend divide compiled"
fi
grep -q '68060-unimplemented 64-bit multiply or divide' "$W/div64.err" || fail "no diagnostic for the 64-bit divide"
test ! -f "$W/div64.o" || fail "an object was left for the failed compile"
AMIX_MUL64=keep "$CC" -O -c "$W/div64.c" -o "$W/div64.o" || fail "AMIX_MUL64=keep refused the 64-bit divide"

# 4. AMIX_SCAN060=1: the object scan fails the compile and removes the object
cat > "$W/movep.c" <<'EOF'
int mp(char *p) { int v; __asm__("movep.w 0(%1),%0" : "=d"(v) : "a"(p)); return v; }
EOF
"$CC" -O -c "$W/movep.c" -o "$W/movep.o" || fail "movep did not compile without the scan"
if AMIX_SCAN060=1 "$CC" -O -c "$W/movep.c" -o "$W/movep.o" > /dev/null 2>&1; then
	fail "AMIX_SCAN060=1 passed a movep"
fi
test ! -f "$W/movep.o" || fail "AMIX_SCAN060=1 left the failed object"
AMIX_SCAN060=1 "$CC" -O -c "$HERE/probe.c" -o "$W/scanned.o" || fail "AMIX_SCAN060=1 refused the expanded probe"

# 5. option handling
if AMIX_MUL64=maybe "$CC" -O -c "$W/plain.c" -o "$W/bad.o" 2>/dev/null; then
	fail "AMIX_MUL64=maybe was accepted"
fi
"$CC" -mmul64 -O -S "$W/plain.c" -o "$W/plain.s" || fail "-S does not take -mmul64"
"$CC" -mno-mul64 -E "$W/plain.c" > /dev/null || fail "-E does not take -mno-mul64"

# 6. fix_asm stays a self-contained function: tools that reuse it extract it
#    with  sed -n '/^fix_asm()/,/^}$/p'  and must get all of it
fn=$(sed -n '/^fix_asm()/,/^}$/p' "$CC")
case "$fn" in
	*"68060-unimplemented 64-bit multiply or divide"*) ;;
	*) fail "fix_asm does not extract whole with sed /^fix_asm()/,/^}\$/" ;;
esac

test $status -eq 0 && echo "test-mul64 PASS: 64-bit multiply expanded, opt-out exact, leftovers refused"
exit $status
