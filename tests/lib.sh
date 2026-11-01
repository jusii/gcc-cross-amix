# tests/lib.sh -- sourced by every gate in tests/.  "make check" (or one
# "make test-<gate>") runs each gate against a staged copy of the toolchain:
# the working copy's wrapper over the installed compiler, so a gate never
# writes into the installed prefix.  Environment:
#   CC                  the m68k-cbm-sysv4-gcc under test
#   W                   a scratch directory for this gate (created)
#   CPUFLAGS            code-generation flags (default -m68020)
#   SYSROOT             the AMIX sysroot (gates that link or read headers)
#   AMIX_ROOT           an AMIX tree (gates that build kernel code)
#   AMIX_KERNEL_CFLAGS, AMIX_USER_CFLAGS   as in build/env.sh
# objdump, nm and the 68060 scanner are the ones next to CC.
set -e
: "${CC:?CC: the m68k-cbm-sysv4-gcc to test}" "${W:?W: a scratch directory}"
CPUFLAGS=${CPUFLAGS:--m68020}
TOOL=${CC%-gcc}
OBJDUMP=$TOOL-objdump
NM=$TOOL-nm
SCAN060=$TOOL-scan060
mkdir -p "$W"
