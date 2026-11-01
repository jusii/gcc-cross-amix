#!/usr/bin/env bash
# The assembler the real gcc driver runs.  Installed as
# <prefix>/lib/gcc-lib/@TARGET@/<gcc version>/as, where the driver looks for
# "as" before anywhere else, so every assembly it produces passes through here:
# the compile half of -c and of a link, .i input, -pipe, -x, -save-temps.
#
# Compiler output is repaired with fix_asm (from amix-gcc-wrapper.sh, copied in
# below when this file is installed) and then assembled by the toolchain's GNU
# as.  Compiler output is recognised by the ".ident" line cc1 ends every file
# with, or by the marker fix_asm leaves; anything else -- hand-written .s, a .S
# after the preprocessor -- is assembled exactly as written.
#
# Options from the driver: -o and the input file are kept; -Qy/-Qn (SVR4 "add
# an .ident" flags GNU as ignores) are dropped; the -m680x0 flags the specs pass
# choose the assembler architecture and are not passed on otherwise.  The last
# CPU flag wins, as it does for the compiler: -m68000/-mc68000 assemble for the
# 68000, -m68020/-mc68020/-m68020-40 for the 68020, -m68030, -m68040 and
# -m68060 for those; with none, -m68020.  (Only -m68030/-m68040/-m68060 used
# to count, so -m68000 code was assembled as 68020 code.)  Everything else
# (-V, the -Wa,<option> list) goes to GNU as unchanged, an option that takes a
# value together with it (-Wa,--defsym,SYM=1 and -Wa,-I,dir are an option and
# its value, not a second input).
set -e

target="@TARGET@"
libdir="$(cd "$(dirname "$0")" && pwd)"
prefix="$(cd "$libdir/../../../.." && pwd)"
as="$prefix/bin/$target-as"

tmp=
cleanup()
{
	if test -n "$tmp"; then rm -f "${tmp:?}"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

@FIX_ASM@

# GNU as 2.8.1 reads its options with getopt_long_only (gas/as.c, with the
# m68k ELF additions from gas/config/tc-m68k.c), and so does this loop, so an
# option's value is never taken for an input file:
#   - short options with a value: -I -o -A -m -Q, the value attached (-Idir)
#     or the next word (-I dir); -a's value is optional and only attached;
#   - long options with a value: --defsym --emulation --itbl, as --opt=val or
#     --opt val, also with one dash and abbreviated (-defsym, --def);
#   - every long option is listed so abbreviations resolve as as resolves them.
as_long_opts="help mri nocpp statistics version dump-config verbose emulation
defsym itbl pic register-prefix-optional bitwise-or base-size-default-16
base-size-default-32 disp-size-default-16 disp-size-default-32"
as_short_opts=JKLMRWZfaDIovwXtlSAmkQV

# as_long NAME: set aslong to the long option NAME selects (exact, or the one
# option it abbreviates), "?" if it abbreviates several, empty if none.
as_long()
{
	local o n=0
	aslong=
	for o in $as_long_opts; do
		if test "$o" = "$1"; then aslong=$o; return; fi
		case "$o" in "$1"*) aslong=$o; n=$((n + 1)) ;; esac
	done
	test $n -le 1 || aslong="?"
}

# as_arch OPTION: an -m option (-m<value>): CPU flags choose the assembler
# architecture, the last one winning; any other -m flag is dropped.
as_arch()
{
	case "$1" in
		-m68000|-mc68000) asarch=-m68000 ;;
		-m68020|-mc68020|-m68020-40) asarch=-m68020 ;;
		-m68030|-m68040|-m68060) asarch=$1 ;;
	esac
}

asarch=-m68020
asargs=()
out=
input=
while test $# -gt 0; do
	case "$1" in
		-)
			input=-
			shift
			continue
			;;
		-*) ;;
		*)
			test -z "$input" || { echo "amix as wrapper: more than one input ($input, $1)" >&2; exit 1; }
			input=$1
			shift
			continue
			;;
	esac
	# a long option: "--name", or "-name" unless it is a single short option
	name=
	case "$1" in
		--?*) name=${1#--} ;;
		-??*|-[!$as_short_opts]) name=${1#-} ;;
	esac
	aslong=
	test -z "$name" || as_long "${name%%=*}"
	if test -n "$aslong" || test "${1#--}" != "$1"; then
		case "$aslong:$name" in
			defsym:*=*|emulation:*=*|itbl:*=*)
				asargs+=("$1")
				;;
			defsym:*|emulation:*|itbl:*)
				test $# -gt 1 || { echo "amix as wrapper: $1 needs an argument" >&2; exit 1; }
				asargs+=("$1" "$2")
				shift
				;;
			*)
				asargs+=("$1")
				;;
		esac
		shift
		continue
	fi
	# short options, possibly several in one word: the first one that takes
	# a value ends the word, its value being the rest or the next word
	flags=${1#-}
	pre=
	opt=
	while test -n "$flags"; do
		c=${flags:0:1}
		flags=${flags:1}
		case "$c" in
			[IoAmQ]) opt=$c; break ;;
			a) pre=$pre$c$flags; flags=; break ;;
			*) pre=$pre$c ;;
		esac
	done
	if test -z "$opt"; then
		asargs+=("$1")
		shift
		continue
	fi
	test -z "$pre" || asargs+=("-$pre")
	if test -z "$flags"; then
		test $# -gt 1 || { echo "amix as wrapper: -$opt needs an argument" >&2; exit 1; }
		val=$2
		shift
	else
		val=$flags
	fi
	case "$opt" in
		o) out=$val ;;
		m) as_arch "-m$val" ;;
		Q) ;;
		*) asargs+=("-$opt" "$val") ;;
	esac
	shift
done

case "${AMIX_MUL64:-expand}" in
	expand|keep) ;;
	*)
		echo "amix as wrapper: AMIX_MUL64 must be 'expand' or 'keep', not '$AMIX_MUL64'" >&2
		exit 1
		;;
esac

# Standard input (-pipe, or no input named) is read into a file first.
if test -z "$input" || test "$input" = -; then
	tmp="$(mktemp "${TMPDIR:-/tmp}/amix-as.XXXXXX.s")"
	cat > "$tmp"
	input=$tmp
fi

if grep -Eq '^[[:space:]]*\.ident[[:space:]]+"GCC: \(GNU\) |^\| amix fix_asm$' "$input"; then
	if test "$input" != "$tmp"; then
		tmp="$(mktemp "${TMPDIR:-/tmp}/amix-as.XXXXXX.s")"
		cp "$input" "$tmp"
	fi
	# fix_asm names the C file in its diagnostics: the one cc1 recorded.
	src=$(sed -n 's/^[[:space:]]*\.file[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$tmp" | head -n 1)
	src=${src:-$input} fix_asm "$tmp"
	input=$tmp
fi

"$as" "$asarch" "${asargs[@]}" ${out:+-o "$out"} "$input"

# Optional post-check: AMIX_SCAN060=1 runs the installed scanner over the
# object and fails the compile, removing the object, if it holds an instruction
# the 68060 does not implement (64-bit multiply or divide, MOVEP, CMP2, CHK2,
# CAS2).  It decides from the encoding, so it also sees what inline asm or the
# assembler produced, not just what fix_asm looked for.
case "${AMIX_SCAN060:-0}" in
	0|no|'') ;;
	*)
		obj=${out:-a.out}
		if ! "$prefix/bin/$target-scan060" --quiet "$obj" >&2; then
			rm -f "${obj:?}"
			echo "amix as wrapper: ${src:-$input}: 68060 scan failed (AMIX_SCAN060)" >&2
			exit 1
		fi
		;;
esac
