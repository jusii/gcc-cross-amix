#!/bin/sh
# Regression test for the DT_NEEDED entries a dynamic link records (see
# resolve_lib in amix-gcc-wrapper.sh).  Only libc.so.1 carries a DT_SONAME on
# this target; libsocket.so, libnsl.so and the stock libX*.so have none.  For a
# SONAME-less shared object ld records the name it was GIVEN, so handing it an
# absolute path -- as the wrapper used to, having resolved every -lNAME to a
# file in the build host's sysroot -- baked that host path into the executable:
#
#   NEEDED  [/home/<user>/opt/amix-cross/m68k-cbm-sysv4/sysroot/usr/lib/libsocket.so]
#
# which exists on no AMIX box.  The link succeeded, the binary looked fine, and
# it died at exec time on the guest.  The wrapper now passes -L<dir> -lNAME, so
# ld records the bare "libsocket.so" that the guest's /usr/lib actually holds.
#
# This gate links a program against -lsocket -lnsl and reads the dynamic
# section.  It requires, at once:
#   (a) no NEEDED entry mentioning the build host's sysroot (the defect);
#   (b) "libsocket.so" and "libnsl.so" present under their bare names, so the
#       libraries are still linked and not merely dropped; and
#   (c) "/usr/lib/libc.so.1" still present -- libc is the one library named by
#       path on purpose, because its DT_SONAME is what ld records.
# (c) is the half a careless fix breaks: routing libc through -lc as well would
# make ld pick up the static stub archive in /usr/ccs/lib and the executable
# would lose its libc dependency entirely.
#
# The test program defines select/syslog/seteuid itself.  Those are BSD entry
# points that libsocket.so imports but the stock shared libc.so.1 does not
# export (it has _abi_select and friends; the plain names live in the static
# /usr/ccs/lib stubs), so without them the link stops on libsocket.so's own
# undefined references.  That gap is a property of the AMIX sysroot, not of the
# wrapper, and stubbing it here keeps this gate about DT_NEEDED alone.
#
# Failure mode against the PRE-FIX wrapper (proof this test bites): check (a)
# reports two NEEDED entries carrying the absolute sysroot path.
. "$(dirname "$0")/lib.sh"
printf '%s\n' \
	'/* Pulls in two SONAME-less shared libraries from the AMIX sysroot. */' \
	'extern int socket();' \
	'extern int t_open();' \
	'/* BSD entry points libsocket.so imports; absent from the shared libc. */' \
	'int select(void)  { return -1; }' \
	'int syslog(void)  { return 0; }' \
	'int seteuid(void) { return -1; }' \
	'int main(void) { return socket(2, 1, 0) + t_open(); }' \
	> $W/dtneeded.c
"$CC" $CPUFLAGS -o $W/dtneeded $W/dtneeded.c -lsocket -lnsl
status=0; \
needed="$("$OBJDUMP" -p $W/dtneeded \
	| sed -n 's/^[ \t]*NEEDED[ \t]*//p')"; \
echo "NEEDED entries:"; printf '%s\n' "$needed" | sed 's/^/  /'; \
if printf '%s\n' "$needed" | grep -Fq "$SYSROOT"; then \
	echo "  FAIL a NEEDED entry carries the build host's sysroot path"; status=1; \
else \
	echo "  ok   no NEEDED entry carries the build host's sysroot path"; \
fi; \
for lib in libsocket.so libnsl.so; do \
	if printf '%s\n' "$needed" | grep -qx "$lib"; then \
		echo "  ok   $lib recorded under its bare name"; \
	else \
		echo "  FAIL $lib is not recorded as a bare name"; status=1; \
	fi; \
done; \
if printf '%s\n' "$needed" | grep -qx '/usr/lib/libc.so.1'; then \
	echo "  ok   /usr/lib/libc.so.1 still recorded from its DT_SONAME"; \
else \
	echo "  FAIL the libc.so.1 dependency is gone"; status=1; \
fi; \
test $status -eq 0 && echo "test-dtneeded PASS: guest-resolvable names only, libc SONAME intact"
exit $status
