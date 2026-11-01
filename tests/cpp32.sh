#!/bin/sh
# make test-cpp32: the preprocessor evaluates #if in 32 bits, as AMIX's does.
#
# gcc is configured for an i686 host.  Built as 64-bit code, its cpp did #if
# arithmetic in a 64-bit long: "#if (1 << 31) < 0" and "#if 0xffffffff + 1 ==
# 0" took the false branch, where the native AMIX cpp (and a 32-bit host
# build) takes the true one, so a header that tests a sign bit or a wrap chose
# the other branch.  Each line below must survive preprocessing.
. "$(dirname "$0")/lib.sh"
status=0
cd "$W"
cat > cpp32.c <<'EOF2'
#if (1 << 31) < 0
sign_bit_negative
#endif
#if 0xffffffff + 1 == 0
unsigned_wraps
#endif
#if 0x7fffffff + 1 < 0
signed_wraps
#endif
EOF2
out=$("$CC" -E cpp32.c 2>cpp32.err)
for w in sign_bit_negative unsigned_wraps signed_wraps; do
	if printf '%s\n' "$out" | grep -qx "$w"; then echo "  ok   $w"
	else echo "  FAIL $w: the #if took the 64-bit branch"; status=1; fi
done
test $status -eq 0 && echo "test-cpp32 PASS: #if arithmetic is 32-bit"
exit $status
