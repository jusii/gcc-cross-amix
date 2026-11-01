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
# choose the assembler architecture -- the last of -m68030, -m68040 or -m68060,
# else -m68020 -- and are not passed on otherwise.  Everything else (-V, the
# -Wa,<option> list) goes to GNU as unchanged.
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

asarch=-m68020
asargs=()
out=
input=
while test $# -gt 0; do
	case "$1" in
		-o)
			test $# -gt 1 || { echo "amix as wrapper: -o needs an argument" >&2; exit 1; }
			out=$2
			shift
			;;
		-m68030|-m68040|-m68060)
			asarch=$1
			;;
		-m*|-Qy|-Qn)
			;;
		-)
			input=-
			;;
		-*)
			asargs+=("$1")
			;;
		*)
			test -z "$input" || { echo "amix as wrapper: more than one input ($input, $1)" >&2; exit 1; }
			input=$1
			;;
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
