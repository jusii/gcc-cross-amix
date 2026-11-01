#!/usr/bin/env bash
set -e

target="@TARGET@"
bindir="$(cd "$(dirname "$0")" && pwd)"
prefix="$(cd "$bindir/.." && pwd)"
real="$bindir/$target-gcc.real"
as="$bindir/$target-as"
ld="$bindir/$target-ld"
sysroot="${AMIX_SYSROOT:-$prefix/$target/sysroot}"
crt_dir="${AMIX_CRT_DIR:-$sysroot/usr/ccs/lib}"

# The real driver finds cc1, cpp and its specs under the GCC_EXEC_PREFIX it
# is given rather than the prefix compiled into it, so the installed tree
# works wherever it is moved or copied.
export GCC_EXEC_PREFIX="$prefix/lib/gcc-lib/"

common_cflags=(-I"$sysroot/usr/include")
default_lib_dirs=("$sysroot/usr/lib")
tmpfiles=()

# Temporary files go on tmpfiles; the EXIT trap removes them.  The link step
# runs ld as a child, not with exec, so the trap still runs after it, and an
# interrupt exits (through the EXIT trap) instead of carrying on.
cleanup()
{
	local f
	for f in "${tmpfiles[@]}"; do
		rm -f "${f:?}" 2>/dev/null || true
	done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fix_asm()
{
	# SGS ".swbeg &N" (emitted before every switch jump table) occupies
	# 4 bytes under the native SGS assembler, and gcc's dispatch is
	# hard-coded around that: "jmp 6(%pc,%d0.w)" expects the table at
	# ext-word+6 = jmp-end+4.  GNU as parses .swbeg but emits ZERO
	# bytes, so every switch case is entered 4 bytes late, skipping its
	# first instruction(s) and branching on stale condition codes.
	# Replace .swbeg with an explicit 4-byte filler to restore the
	# layout the compiler assumed.  (Found via amix-packagemanager
	# contents-fsck: validate_rest's switch misdispatched on the box.)
	perl -pi -e 's/^(\s*)\.swbeg\s+&(\d+)[ \t]*$/$1.long $2/' "$1"

	# gcc's SGS output spells the 68020 32-bit/32-bit divide-with-
	# remainder as "tdivs.l <ea>,%dR:%dQ" / "tdivu.l ..." (remainder in
	# dR, quotient in dQ).  These SGS mnemonics are produced by
	# config/m68k/sgs.h, which renames the Motorola "divsl"/"divul" to
	# "tdivs"/"tdivu".  GNU as 2.8.1 does not know them as the 32-bit-
	# dividend form: it assembles "tdivs.l <ea>,%dR:%dQ" to the SAME
	# encoding as "divs.l <ea>,%dR:%dQ", i.e. the 64-bit-dividend
	# "DIVS.L Dr:Dq" (SIZE bit set), so dR is taken as the HIGH 32 bits
	# of the dividend instead of the remainder destination.  That word
	# holds an unrelated value, the 64-bit quotient overflows 32 bits,
	# and the 68020 then leaves the operand registers UNCHANGED -- so
	# both "%" and "/" on a variable divisor return garbage (measured:
	# 351 % 151 -> -2147408448, 351 / 151 -> 351).  Undo the SGS rename
	# back to the Motorola/GNU-as "divsl.l"/"divul.l" (32-bit dividend,
	# 32r:32q) spelling, which assembles to the correct SIZE-clear
	# encoding with the remainder in dR and the quotient in dQ.  Verify
	# with objdump: the fixed form disassembles as "divsll"/"divull",
	# the broken one as "divsl"/"divul".  (Affects every variable-divisor
	# divide/modulo the compiler emits, at both -O0 and -O.)
	perl -pi -e 's/^(\s*)tdivs(?=[.\s])/${1}divsl/; s/^(\s*)tdivu(?=[.\s])/${1}divul/;' "$1"

	# gcc emits single-precision FP multiply/divide as the 68881/68882
	# "fsglmul"/"fsgldiv" (single-precision ROUNDING, extended-precision
	# operands).  config/m68k/amix.h defines FSGLDIV_USE_S/FSGLMUL_USE_S,
	# which makes the m68k.md templates spell the register-to-register
	# form with a ".s" suffix ("fsgldiv.s %fp1,%fp0") the way the native
	# SGS assembler wants it.  GNU as 2.8.1 disagrees: in its grammar the
	# suffix names the SOURCE OPERAND FORMAT, and when the source is an
	# FPU register the data is by definition 80-bit extended, so ".x" is
	# the only legal suffix on the register-register form.  It rejects the
	# ".s" spelling outright -- "Error: operands mismatch -- statement
	# `fsgldiv.s %fp1,%fp0' ignored" -- which blocks assembly of ANY C
	# using "float" multiply or divide (measured: 15 fsgldiv + 6 fsglmul
	# rejections in one small float test file at -O).  Both spellings mean
	# the same instruction: the single-precision rounding is encoded in
	# the "sgl" of the mnemonic, not in the suffix.  Rewrite to ".x".
	#
	# ONLY the register-to-register form may be rewritten.  With a
	# non-register source the ".s" suffix is load-bearing and legal --
	# "fsgldiv.s 12(%fp),%fp0" (memory) and "fsgldiv.s %d0,%fp0" (data
	# register) both assemble, and both encode a genuinely different
	# instruction (R/M=1, source specifier "single") from the ".x"
	# register-register form (R/M=0).  gcc emits all three shapes, so the
	# match below requires BOTH operands to be %fp0-%fp7 registers and
	# leaves memory/data-register/immediate sources alone.  Verify with
	# objdump: the rewritten form disassembles as "fsgldivx"/"fsglmulx",
	# the untouched legal ones stay "fsgldivs"/"fsglmuls".  ("make
	# test-float" gates both halves.)
	#
	# Note the frame pointer prints as "%fp" with no digit, so the
	# "%fp[0-7]" match cannot mistake "12(%fp)" for an FPU register.
	perl -pi -e 's{^(\s*)fsgl(div|mul)\.s(\s+%fp[0-7]\s*,\s*%fp[0-7])(\s*)$}{$1fsgl$2.x$3$4}' "$1"

	# Bit-field operand: gcc 2.7.2.3 copies an inline "asm" template into its
	# output verbatim, so hand-written m68k assembly that spells the bit-field
	# offset and width the Motorola way -- "bfffo %d3{#0:#32},%d2", which is
	# how portable m68k C writes it (NetBSD's soft-FPU fpu_subr.c, for one) --
	# reaches the assembler unchanged.  On this target "#" is not an immediate
	# prefix at all: the SGS immediate prefix is "&", and GNU as 2.8.1 lists
	# "#" in line_comment_chars (gas/config/tc-m68k.c), so its scrubber drops
	# everything from the "#" to end of line before the m68k parser sees it --
	# the same way it silently eats a stray "moveq #1,%d0":
	#
	#   Error: Missing operand
	#   Error: operands mismatch -- statement `bfffo %d3{' ignored
	#
	# Rewrite the "#" inside the bit-field braces to "&".  That is exactly what
	# gcc's own bit-field patterns already print -- "bfextu (%a0){&0:&5},%d0"
	# assembles today -- so the repaired line is spelled the way the rest of the
	# file is.  "&" rather than a bare number: GNU as needs a prefix as soon as
	# the offset or width is a symbol.  Its operand splitter only breaks at the
	# ":" when the next character is one of a small set (the digits, "&", "#",
	# a register prefix, "(", "@"), so "{&BOFF:&WID}" assembles while the bare
	# "{BOFF:WID}" is a "Bad expression".
	#
	# Only what is between the braces is touched, so "#APP"/"#NO_APP" and any
	# other "#" on the line are left alone, and the register form "{%d0:%d1}"
	# and the already-correct "{&0:&5}" pass through unchanged.  All eight m68k
	# bit-field mnemonics are covered.  gcc's own codegen emits seven of them
	# (config/m68k/m68k.md) and already gets the prefix right, so in practice
	# this only ever fires on inline asm -- but any of the eight can arrive that
	# way, and bfffo, which gcc has no pattern for at all, arrives ONLY that
	# way.  Verify with objdump: offset and width must survive as bits 10:6 and
	# 4:0 of the extension word with the Do/Dw register-select bits clear (a
	# width of 32 encodes as 0).  ("make test-bitfield" gates this.)
	perl -pi -e '
		s{^(\s*bf(?:chg|clr|exts|extu|ffo|ins|set|tst)\s[^\n]*?\{)([^\n{}]*)(\})}{
			my ($head, $field, $tail) = ($1, $2, $3);
			$field =~ s/[#]/&/g;
			"$head$field$tail";
		}egm;
	' "$1"

	perl -pi -e 's/^(\s*\.lcomm\s+[^,]+,[^,]+),\d+\s*$/$1\n/' "$1"

	# Restore Motorola/GNU operand order for compares.  config/m68k/sgs.h
	# defines SGS_CMP_ORDER ("Takes cmp operands in reverse order"), so
	# every compare template in config/m68k/m68k.md prints its two
	# operands the other way round from what GNU as expects.
	#
	# This covers the integer "cmp.[bwl]" AND the 68881 "fcmp.[sdx]".
	# For fcmp the m68k.md patterns have three branches, and in all three
	# -- across SFmode, DFmode and XFmode -- the SGS template is the exact
	# operand-swap of the non-SGS template, with cc_status set identically
	# in both.  So swapping the two printed operands is enough; the
	# condition-code sense gcc assumed is preserved untouched:
	#
	#   both operands FPU regs   SGS "fcmp.x %0,%1"   GNU "fcmp.x %1,%0"
	#   FP reg vs memory/dreg    SGS "fcmp.s %0,%f1"  GNU "fcmp.s %f1,%0"
	#   memory/dreg vs FP reg    SGS "fcmp.s %1,%f0"  GNU "fcmp.s %f0,%1"
	#
	# The two shapes fail differently, and one of them fails SILENTLY.
	# GNU as requires an FPU register as the DESTINATION, so the forms
	# with memory on the right are rejected outright ("operands mismatch
	# -- statement `fcmp.d %fp0,16(%fp)' ignored").  But when BOTH
	# operands are FPU registers the reversed spelling is still valid
	# syntax and assembles silently to a DIFFERENT encoding: "fcmp.x
	# %fp2,%fp0" is f200 0838 (source fp2, destination fp0) whereas
	# "fcmp.x %fp0,%fp2" is f200 0138.  FCMP computes destination minus
	# source, so the unswapped form compares the operands the wrong way
	# round and the following fbgt/fsgt tests the REVERSED relation --
	# e.g. a "secs > 0.0" guard in cross-built code evaluates as
	# "0.0 > secs".  Verify with objdump: FCMP computes <second operand>
	# minus <first operand>, so the value the C source has on the LEFT of
	# the comparison must end up as the SECOND operand.  ("make test-fcmp"
	# gates both shapes.)
	#
	# The split is parenthesis-aware because memory operands contain
	# commas of their own, e.g. "fcmp.s 4(%a0,%d0.l),%fp1".
	perl -0pi -e '
		# Rule 6 must not run twice on one file (a second swap undoes the
		# first); fix_asm marks a file it has repaired, below.  Every other
		# rule leaves nothing it would match again.
		my $done = /^\| amix fix_asm$/m;
		sub split_operands {
			my ($s) = @_;
			my $depth = 0;
			for (my $i = 0; $i < length($s); $i++) {
				my $ch = substr($s, $i, 1);
				$depth++ if $ch eq "(";
				$depth-- if $ch eq ")";
				if ($ch eq "," && $depth == 0) {
					return (substr($s, 0, $i), substr($s, $i + 1));
				}
			}
			return;
		}
		s{^(\s*(?:cmp\.[bwl]|fcmp\.[bwlsdxp])\s+)([^\n]+)$}{
			my ($prefix, $ops) = ($1, $2);
			my ($left, $right) = split_operands($ops);
			defined $right ? "$prefix$right,$left" : "$prefix$ops";
		}egm unless $done;
		# Rounding-precision opcodes with an FPn source: gcc 2.7.2.3 emits
		# the size suffix of the original C type (.s/.d), but a register
		# source is always extended precision and gas rejects anything but
		# .x.  The value is unaffected -- these opcodes round the RESULT to
		# the precision named in the mnemonic, whatever the source is called.
		# FSGLMUL/FSGLDIV are handled by the rule above; this is the
		# FSxxx/FDxxx family, which gcc emits at -m68040.
		s{^(\s*f[sd](?:add|sub|mul|div|mov|abs|neg|sqrt))\.[bwlsdp](\s+%fp[0-7],%fp[0-7]\s*)$}{$1.x$2}gm;
		# ...and this gas knows FSMOV by the short name but not FDMOV, which
		# it only accepts spelled FDMOVE.  An asymmetry in its opcode table,
		# not a difference between the instructions.  Must run after the rule
		# above, which matches on the short spelling.
		s{^(\s*)fdmov(\.)}{$1fdmove$2}gm;
		# Two more spellings gas will not take, both from the float-to-int
		# sequence gcc emits at -m68040: it saves FPCR, sets round-to-zero,
		# converts and restores.  Suffixless `fmovm` (the register-list form
		# in prologues) is fine; only the sized control-register form is not.
		s{^(\s*)fmovm(\.[a-z])}{$1fmovem$2}gm;
		s{^(\s*mov)(\s+&\d+,%d[0-7]\s*)$}{$1.l$2}gm;
	' "$1"

	# The marker: a comment line, so the object is the same with or without
	# it.  A file carrying it is in GNU as syntax already -- "-S" output, say,
	# fed back to the compiler -- and rule 6 above leaves it alone.
	grep -q '^| amix fix_asm$' "$1" || printf '%s\n' '| amix fix_asm' >> "$1"

	# 68060: expand the 32x32->64 multiply.  gcc 2.7.2.3 emits the 64-bit-
	# product "muls.l/mulu.l <ea>,%dH:%dL" (MULS.L/MULU.L <ea>,Dh:Dl, ext-word
	# SIZE bit set) for every divide or modulo by a constant -- the
	# smulsi3_highpart/umulsi3_highpart patterns -- and for (u64)a*b, at every
	# optimisation level.  The 68020/030/040 execute it; the 68060 does not
	# implement it and raises vector 61 ("unimplemented integer instruction"),
	# which AMIX has no emulation for, so the process is killed.  gcc has no
	# switch that avoids the form, so each such line becomes an equivalent
	# sequence of 16x16 "mulu.w" partial products that every 680x0 from the
	# 68020 up executes.  The sequence
	#
	#   - evaluates <ea> exactly once, first, before the stack pointer moves
	#     (so %sp- and %fp-relative operands read what the original did);
	#   - writes only %dH:%dL; every other register is saved and restored;
	#   - leaves the CCR as the hardware instruction does: N = bit 63,
	#     Z = the 64-bit result is zero, V = C = 0, X unchanged (X is saved
	#     with "mov.w %cc" before the first add and put back after the last);
	#   - keeps all its data above %sp (32 bytes, interrupt- and signal-safe)
	#     and leaves %sp where it found it.
	#
	# Signed products are the unsigned product minus (a<0 ? b<<32 : 0) and
	# (b<0 ? a<<32 : 0).  ON by default; AMIX_MUL64=keep, or -mmul64 on the
	# command line, leaves the 64-bit form alone for code that must reproduce
	# older objects and will never run on a 68060.  A line that does not
	# contain the 64-bit form is not touched, so an object without one is
	# byte-identical either way.  ("make test-mul64" gates the encoding and
	# "make test-mul64-run" the results on a 68060 and a 68020 under qemu.)
	local mul64="${amix_mul64_mode:-${AMIX_MUL64:-expand}}"
	test "$mul64" = keep && return 0
	perl -pi -e '
		if (/^(\s*)mul([su])\.l\s+(.+?),(%d[0-7]):(%d[0-7])\s*$/) {
			my ($i, $sg, $ea, $dh, $dl) = ($1, $2, $3, $4, $5);
			# frame, from %sp: 0..16 %d0-%d4, 20 CCR then result flags,
			# 24 a = %dL then high word, 28 b = <ea> then low word
			my @o = (
			  "mov.l $ea,-(%sp)", "mov.l $dl,-(%sp)", "subq.l &4,%sp",
			  "mov.l %d4,-(%sp)", "mov.l %d3,-(%sp)", "mov.l %d2,-(%sp)",
			  "mov.l %d1,-(%sp)", "mov.l %d0,-(%sp)", "mov.w %cc,20(%sp)",
			  "mov.l 24(%sp),%d0", "mov.l 28(%sp),%d1",
			  "mov.l %d0,%d2", "swap %d2", "mov.l %d1,%d3", "swap %d3",
			  "mov.w %d0,%d4", "mulu.w %d1,%d4", "mulu.w %d3,%d0",
			  "mulu.w %d2,%d1", "mulu.w %d3,%d2",
			  "add.l %d1,%d0", "moveq &0,%d1", "addx.l %d1,%d1",
			  "swap %d1", "add.l %d1,%d2",
			  "mov.l %d0,%d1", "clr.w %d1", "swap %d1", "add.l %d1,%d2",
			  "swap %d0", "clr.w %d0", "add.l %d0,%d4",
			  "moveq &0,%d1", "addx.l %d1,%d2");
			push @o, ("mov.l 24(%sp),%d0", "mov.l 28(%sp),%d1",
			  "tst.l %d0", "smi %d3", "extb.l %d3", "and.l %d1,%d3",
			  "sub.l %d3,%d2", "tst.l %d1", "smi %d3", "extb.l %d3",
			  "and.l %d0,%d3", "sub.l %d3,%d2") if $sg eq "s";
			push @o, ("mov.w 20(%sp),%cc",
			  "mov.l %d2,24(%sp)", "mov.l %d4,28(%sp)",
			  "tst.l %d4", "sne %d3", "and.l &1,%d3", "or.l %d2,%d3",
			  "mov.l %d3,20(%sp)",
			  "mov.l (%sp)+,%d0", "mov.l (%sp)+,%d1", "mov.l (%sp)+,%d2",
			  "mov.l (%sp)+,%d3", "mov.l (%sp)+,%d4",
			  "mov.l 4(%sp),$dh", "mov.l 8(%sp),$dl", "tst.l (%sp)",
			  "lea 12(%sp),%sp");
			$_ = join("", map { "$i$_\n" } @o);
		}
	' "$1"
	# Fail closed on any 64-bit form still present: an unexpanded multiply,
	# a 64-bit-dividend divide (the 32-bit remainder divide is spelled
	# divsl.l/divul.l by now), or an SGS tdivs/tdivu the rule above missed.
	# gcc emits no 64/32 divide of its own; these can only come from inline
	# asm, and assembling them would trap on a 68060.
	if grep -nE '^[[:space:]]*(mul[su]\.l[[:space:]].*,%d[0-7]:%d[0-7][[:space:]]*$|div[su]\.l[[:space:]].*:|tdiv[su])' "$1" >&2; then
		echo "amix gcc wrapper: ${src:-$1}: 68060-unimplemented 64-bit multiply or divide left (above); AMIX_MUL64=keep or -mmul64 allows it" >&2
		return 1
	fi
}

# fix (linking): emit the ld argument for one "-lNAME", preferring the "-lNAME"
# form over an absolute path.  ld records a shared library in DT_NEEDED under
# the name it was GIVEN, unless the library carries a DT_SONAME of its own.  On
# this target only libc.so.1 and ld.so.1 have a SONAME: libsocket.so, libnsl.so
# and every stock libX*.so have none.  So resolving "-lsocket" to a file in the
# build HOST's sysroot and passing that path positionally, as this function used
# to, baked the host path into the executable --
#
#   NEEDED  [/home/<user>/opt/amix-cross/m68k-cbm-sysv4/sysroot/usr/lib/libsocket.so]
#
# a path that exists on no AMIX box.  Nothing complained: the link succeeded and
# the binary looked correct; it died at exec time on the guest, where the
# runtime linker has only the recorded string to go on.  Passing "-L<dir>"
# followed by "-lNAME" makes ld search for the file itself, and for a library
# found that way it records just the file name ("libsocket.so"), which is what
# the guest's /usr/lib holds.  (binutils 2.8.1 predates "-l:libNAME.so", so the
# search form is the only way to get a bare name recorded.)
#
# Two libraries still have to be named by path, and both are safe:
#
#   libc      the sysroot ships "libc.so.1", not "libc.so", so ld's -l search
#             cannot find it at all.  It is also the one library with a
#             DT_SONAME, so the recorded name is "/usr/lib/libc.so.1" from the
#             SONAME rather than the host path.  (Routing libc through -lc
#             instead would find the static stub archive in /usr/ccs/lib and the
#             executable would silently lose its libc dependency.)
#   libNAME.so.1
#             a versioned DSO with no unversioned name, same search problem.
#             Nothing but libc is shaped like this in the stock sysroot; if one
#             appears, the previous behaviour is kept.
#
# The lookup order below is unchanged, and matches ld's own: the -L directories
# in command-line order, then the sysroot default, and within each directory the
# shared library before the archive.  So "-lNAME" resolves to exactly the file
# this function inspected, provided the same -L list reaches ld -- which is what
# ld_lib_dirs below is for.  ("make test-dtneeded" gates this.)
resolve_lib()
{
	local name="$1"
	local dir candidate

	test "$name" = c && {
		printf '%s\n' "$sysroot/usr/lib/libc.so.1"
		return 0
	}

	for dir in "${lib_dirs[@]}" "${default_lib_dirs[@]}"; do
		test -f "$dir/lib$name.so" && {
			printf '%s\n' "-l$name"
			return 0
		}
		test -f "$dir/lib$name.so.1" && {
			printf '%s\n' "$dir/lib$name.so.1"
			return 0
		}
		test -f "$dir/lib$name.a" && {
			printf '%s\n' "-l$name"
			return 0
		}
	done

	printf 'amix gcc wrapper: cannot resolve -l%s\n' "$name" >&2
	return 1
}

# -mmul64 / -mno-mul64 select the 68060 multiply expansion in fix_asm (default
# expand, i.e. -mno-mul64).  They are wrapper options: gcc 2.7.2.3 knows neither,
# so they are taken off the command line here, before any path hands the
# arguments to the real compiler.  The last one given wins over AMIX_MUL64, and
# the choice reaches the assembler wrapper through AMIX_MUL64.
amix_mul64_mode="${AMIX_MUL64:-expand}"
args=()
for arg in "$@"; do
	case "$arg" in
		-mmul64) amix_mul64_mode=keep ;;
		-mno-mul64) amix_mul64_mode=expand ;;
		*) args+=("$arg") ;;
	esac
done
set -- "${args[@]}"
case "$amix_mul64_mode" in
	expand|keep) ;;
	*)
		echo "amix gcc wrapper: AMIX_MUL64 must be 'expand' or 'keep', not '$amix_mul64_mode'" >&2
		exit 1
		;;
esac
export AMIX_MUL64="$amix_mul64_mode"

has_c=no
has_S=no
has_E=no
has_query=no
for arg in "$@"; do
	case "$arg" in
		-c) has_c=yes ;;
		-S) has_S=yes ;;
		# -M and -MM print dependencies and stop after the preprocessor
		-E|-M|-MM) has_E=yes ;;
		-dumpversion|-dumpmachine|-dumpspecs|-print-libgcc-file-name|-print-file-name=*|-print-prog-name=*|--help)
			has_query=yes ;;
	esac
done

# Questions to the driver (-dumpversion, -print-file-name=..., ...) are
# answered by the real driver; nothing is compiled or linked.  (They used to
# fall through to the link: "-dumpversion" linked a.out.)  So is a bare "-v".
if test "$has_query" = yes || { test $# -eq 1 && test "$1" = -v; }; then
	exec "$real" "$@"
fi

# Every compile goes through the real driver, and the real driver assembles
# through the assembler wrapper it finds under GCC_EXEC_PREFIX
# (lib/gcc-lib/<target>/<version>/as), which runs fix_asm over compiler
# output before handing it to GNU as.  So -c, the compile half of a link, .i
# input from "gcc -E" (ccache, distcc, -save-temps, creduce), -pipe and an
# explicit "-x" all get the repairs; there is no path around them.  The
# assembler wrapper knows compiler output by the .ident line cc1 ends every
# file with, and leaves hand-written assembly (.s, .S) exactly as written.

# -E: preprocessing only; no assembly, nothing to repair.  The target include
# path goes first, as for a compile.  (Before -E was dispatched here, "gcc -E
# foo.c" fell through to the link path and compiled and linked instead, and
# autoconf fell back to the build host's /lib/cpp.)
if test "$has_E" = yes; then
	exec "$real" "${common_cflags[@]}" "$@"
fi

# -c: the real driver does everything, with gcc's own rules for -o and for
# naming objects (one ./<basename>.o per input in the working directory when
# there is no -o) -- for .c, .i, .s and .S alike.
if test "$has_c" = yes && test "$has_S" = no; then
	prev=
	for arg in "$@"; do
		if test "$prev" = -o; then
			for input in "$@"; do
				case "$input" in -*) continue ;; esac
				if test "$input" != "$arg" && test -e "$input" && test "$input" -ef "$arg"; then
					echo "amix gcc wrapper: refusing to overwrite input file '$input'" >&2
					exit 1
				fi
			done
		fi
		prev=$arg
	done
	exec "$real" "${common_cflags[@]}" "$@"
fi

# -S: the assembly is repaired before it is written, so what -S produces is
# what the compiler assembles: valid GNU as input with the marker fix_asm
# leaves, which a later "gcc -c foo.s" recognises and does not repair twice.
# Each C or preprocessed-C input is compiled on its own to a temporary file;
# the result goes where gcc would put it (-o, or ./<basename>.s), and "-o -"
# writes it to standard output.  Other inputs produce nothing under -S, as with
# gcc.
if test "$has_S" = yes; then
	s_flags=()
	s_inputs=()
	s_out=
	lang=
	while test $# -gt 0; do
		case "$1" in
			-o) test $# -gt 1 || { echo "amix gcc wrapper: -o needs an argument" >&2; exit 1; }
			    s_out=$2; shift 2; continue ;;
			-o*) s_out=${1#-o} ;;
			-x) test $# -gt 1 || { echo "amix gcc wrapper: -x needs an argument" >&2; exit 1; }
			    lang=$2; shift 2; continue ;;
			-I|-D|-U|-include|-imacros|-idirafter|-iprefix|-iwithprefix|-iwithprefixbefore|-aux-info|-b|-V)
			    test $# -gt 1 || { echo "amix gcc wrapper: $1 needs an argument" >&2; exit 1; }
			    s_flags+=("$1" "$2"); shift 2; continue ;;
			-S) ;;
			-*) s_flags+=("$1") ;;
			*) s_inputs+=("${lang:-none}:$1") ;;
		esac
		shift
	done
	n=0
	for li in "${s_inputs[@]}"; do
		l=${li%%:*} f=${li#*:}
		case "$l:$f" in none:*.c|none:*.i|c:*|cpp-output:*) n=$((n + 1)) ;; esac
	done
	if test $n -gt 1 && test -n "$s_out" && test "$s_out" != -; then
		echo "amix gcc wrapper: -o with -S and multiple sources is not supported" >&2
		exit 1
	fi
	for li in "${s_inputs[@]}"; do
		l=${li%%:*} f=${li#*:}
		case "$l:$f" in
			none:*.c|none:*.i) xl=() ;;
			c:*|cpp-output:*) xl=(-x "$l") ;;
			*) continue ;;
		esac
		dest=${s_out:-$(basename "$f")}
		test -n "$s_out" || dest=${dest%.*}.s
		if test "$dest" != - && test -e "$dest" && test "$dest" -ef "$f"; then
			echo "amix gcc wrapper: refusing to overwrite input file '$f'" >&2
			exit 1
		fi
		asmfile="$(mktemp "${TMPDIR:-/tmp}/amix-gcc.XXXXXX.s")"
		tmpfiles+=("$asmfile")
		"$real" "${common_cflags[@]}" -S "${s_flags[@]}" "${xl[@]}" "$f" -o "$asmfile"
		src=$f fix_asm "$asmfile"
		if test "$dest" = -; then
			cat "$asmfile"
		else
			cp "$asmfile" "$dest"
		fi
	done
	exit 0
fi

# Compile and link.  Options are sorted into three kinds:
#   - linker options, an explicit list (ld_flags, in command-line order);
#   - wrapper link controls (-L, -l, -nostdlib, -nostartfiles, -o);
#   - everything else, which belongs to the compiler and goes to the real
#     driver with each compile (compile_flags), so an option it does not know
#     is reported by gcc, not handed to ld.  (Unknown options used to go to ld:
#     -ansi was an ld error, -include dropped, -Wl,-Map wrote no map.)
# Inputs: .c, .i, .s and .S -- or any file after "-x <language>" -- are
# compiled to objects first; every other file is a linker input, as with gcc.
compile_flags=()
sources=()
objects=()
archives=()
ld_flags=()
lib_dirs=()
libs=()
out=a.out
lang=none
nostdlib=no
nostartfiles=no
verbose=no

need_arg()
{
	test "$1" -gt 1 || { echo "amix gcc wrapper: $2 needs an argument" >&2; exit 1; }
}

while test $# -gt 0; do
	arg="$1"
	case "$arg" in
		-o)
			need_arg $# "$arg"; out="$2"; shift ;;
		-o*)
			out="${arg#-o}" ;;
		-x)
			need_arg $# "$arg"; lang="$2"; shift ;;
		-L)
			need_arg $# "$arg"; lib_dirs+=("$2"); shift ;;
		-L*)
			lib_dirs+=("${arg#-L}") ;;
		-l)
			need_arg $# "$arg"; libs+=("$2"); shift ;;
		-l*)
			libs+=("${arg#-l}") ;;
		-nostdlib)
			nostdlib=yes ;;
		-nostartfiles)
			nostartfiles=yes ;;
		-v)
			verbose=yes; compile_flags+=("$arg") ;;
		# linker options
		-Wl,*)
			IFS=, read -r -a wl <<< "${arg#-Wl,}"
			ld_flags+=("${wl[@]}") ;;
		-Xlinker)
			need_arg $# "$arg"; ld_flags+=("$2"); shift ;;
		-u|-e|-h|-z|-T|-Y)
			need_arg $# "$arg"; ld_flags+=("$arg" "$2"); shift ;;
		-u?*|-e?*|-h?*|-z?*|-T?*|-Y?*)
			ld_flags+=("$arg") ;;
		-s|-r|-N|-n|-static|-shared|-symbolic|-G|-dn|-dy|-dc|-dp|-Bstatic|-Bdynamic|-Bsymbolic)
			ld_flags+=("$arg") ;;
		# compiler options that take a separate argument
		-I|-D|-U|-include|-imacros|-idirafter|-iprefix|-iwithprefix|-iwithprefixbefore|-aux-info|-b|-V)
			need_arg $# "$arg"; compile_flags+=("$arg" "$2"); shift ;;
		# every other option is the compiler's (-O, -g, -f, -m, -W, -D, -ansi,
		# -pedantic, -traditional, -w, -pipe, -save-temps, -dM, -MD, ...)
		-?*)
			compile_flags+=("$arg") ;;
		*)
			case "$lang:$arg" in
				none:*.c|none:*.i|none:*.s|none:*.S)
					sources+=("none:$arg") ;;
				none:*.a|none:*.so|none:*.so.[0-9]*)
					# fix (linking): an archive or shared library named on the
					# command line goes AFTER the objects compiled from the
					# sources, which are appended to objects[] below; single-pass
					# ld meeting "libfoo.a" before "prog.o" would pull in no
					# members.  Plain .o files stay in command-line order.
					archives+=("$arg") ;;
				none:*)
					objects+=("$arg") ;;
				*)
					sources+=("$lang:$arg") ;;
			esac
			;;
	esac
	shift
done

for input in "${sources[@]#*:}" "${objects[@]}" "${archives[@]}"; do
	if test -n "$input" && test -e "$input" && test "$out" -ef "$input"; then
		echo "amix gcc wrapper: refusing to overwrite input file '$input'" >&2
		exit 1
	fi
done

for li in "${sources[@]}"; do
	l=${li%%:*} src=${li#*:}
	xl=()
	test "$l" = none || xl=(-x "$l")
	obj="$(mktemp "${TMPDIR:-/tmp}/amix-gcc.XXXXXX.o")"
	tmpfiles+=("$obj")
	"$real" "${common_cflags[@]}" -c "${compile_flags[@]}" "${xl[@]}" "$src" -o "$obj"
	objects+=("$obj")
done

# Locate the installed target libgcc.a (the freestanding soft-arithmetic
# helpers: 64-bit __udivdi3/__umoddi3/__lshrdi3/... and the DImode<->float
# conversions).  A stock gcc driver pulls this in via -lgcc from its specs, but
# this wrapper hand-rolls the ld command line, so add libgcc.a explicitly.  The
# newest installed version directory wins; if none is present the link proceeds
# without it, preserving the previous behaviour.
libgcc_a=
for cand in "$prefix"/lib/gcc-lib/"$target"/*/libgcc.a; do
	test -f "$cand" && libgcc_a="$cand"
done

# fix (linking): hand ld the library search path.  The -L directories used to be
# consumed by the wrapper alone, for resolve_lib's own lookup, and never reached
# ld -- which was invisible while every -l was turned into an absolute path.  Now
# that resolve_lib emits "-lNAME", ld has to be able to find the same files, in
# the same order: the user's -L directories first, then the sysroot default.
# These also give ld the search path it needs for a shared library's own
# dependencies.
ld_lib_dirs=()
for dir in "${lib_dirs[@]}" "${default_lib_dirs[@]}"; do
	ld_lib_dirs+=(-L"$dir")
done

resolved_libs=()
for lib in "${libs[@]}"; do
	# -lgcc is satisfied by the libgcc.a appended to the link below.
	test "$lib" = gcc && continue
	resolved_libs+=("$(resolve_lib "$lib")")
done
# fix (linking): always link libc, at the END of the library list.  A stock gcc
# driver pulls libc in from its specs regardless of the user's -l flags; this
# wrapper hand-rolls ld, and it used to add libc ONLY when no -l was given at
# all.  So a lone "-lfoo" dropped libc from the link entirely, and the first
# symbols left undefined were crt1.o's own atexit/exit/_environ/__fpstart --
# which reads as a broken toolchain rather than a missing -lc.  Appending it
# after the user's libraries (so their libc references still resolve) means an
# explicit trailing -lc is no longer required; a redundant one is harmless.
# -nostdlib leaves out libc and libgcc.a, as with gcc.
if test "$nostdlib" = no; then
	resolved_libs+=("$(resolve_lib c)")
else
	libgcc_a=
fi

# The startup objects; -nostartfiles or -nostdlib leaves them out.
startfiles=()
endfiles=()
if test "$nostdlib" = no && test "$nostartfiles" = no; then
	for crt in crt1.o crti.o crtn.o; do
		test -f "$crt_dir/$crt" || {
			echo "amix gcc wrapper: missing $crt_dir/$crt; set AMIX_CRT_DIR" >&2
			exit 1
		}
	done
	startfiles=("$crt_dir/crt1.o" "$crt_dir/crti.o")
	endfiles=("$crt_dir/crtn.o")
fi

# libgcc.a goes LAST (after the user's libraries, before crtn): it is a leaf
# dependency, so any preceding static archive whose members reference the 64-bit
# helpers must come before it for single-pass ld to resolve them.  This mirrors
# a stock gcc driver, which appends -lgcc at the end of the link.
ld_cmd=("$ld" -o "$out" "${startfiles[@]}" \
	"${objects[@]}" "${archives[@]}" "${ld_flags[@]}" \
	"${ld_lib_dirs[@]}" "${resolved_libs[@]}" \
	${libgcc_a:+"$libgcc_a"} \
	"${endfiles[@]}")
test "$verbose" = no || echo " ${ld_cmd[*]}" >&2
"${ld_cmd[@]}"
