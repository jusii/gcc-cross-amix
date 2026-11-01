#!/bin/sh
# Regression test for object placement with "-c" and no "-o" (see the -c
# dispatch in amix-gcc-wrapper.sh).  A C compiler writes the object into the
# CURRENT WORKING DIRECTORY under the input's basename: "cc -c ../src/foo.c"
# produces "./foo.o", and so does "cc -c ../src/foo.s".  The wrapper got this
# wrong in two different ways, one per input kind, and both are gated here.
#
# .c sources: the wrapper stripped only the suffix and kept the directory part,
# so it wrote "../src/foo.o" -- next to the SOURCE.  That breaks any build whose
# sources are not in the directory make runs in: a VPATH/srcdir build (gcc's own
# build compiles "../gcc-src/*.c" into the build directory; imake/X11 and
# autoconf packages configured from a separate build tree do the same), and
# equally a plain non-recursive Makefile naming its sources "sub/foo.c".  The
# compile reports success, so the failure surfaces later and somewhere else --
# "ld: cannot open c-parse.o: No such file or directory" -- and meanwhile the
# stray objects are left in the source tree where another build can pick them up.
#
# .s/.S inputs: these are passed to the real compiler rather than assembled by
# the wrapper, and that path forwarded an EMPTY "-o" when the command line
# carried none.  gcc 2.7.2.3 drops an empty argument from the command line it
# builds, so the assembler ran as
#
#     as -V -Qy -o ../src/foo.s
#
# with the SOURCE as its output file and stdin as its input.  In a
# non-interactive build as read an empty stdin, WROTE AN OBJECT OVER THE
# ASSEMBLY SOURCE, produced no .o anywhere and exited 0; on a terminal the
# compile hung.  A plain ".s.o:  $(CC) -c $<" suffix rule hit this on every file
# it touched, so the source-integrity check below is the important one.
#
# The halves checked here, for .c, .s and .S alike:
#   (a) no -o: the object lands in the cwd as ./<basename>.o, NOT beside the
#       source, and the source file itself is byte-for-byte unchanged; and
#   (b) an explicit -o is still honoured verbatim, including a path that points
#       into another directory (the wrapper must not "helpfully" relocate it).
# Everything is checked by looking at the FILES, not by trusting the exit status
# -- the pre-fix wrapper exits 0 in every failing case.  Each compile runs in a
# subshell so the recipe shell stays in the make directory and a relative
# BUILDDIR keeps resolving; stdin is /dev/null so a reintroduced empty "-o"
# fails the gate instead of hanging it.
#
# Failure modes against the PRE-FIX wrapper (proof this test bites).  Against the
# wrapper before 8ca9e3b the .c case fails on two counts -- the object is missing
# from objdir/ and present in objdir-src/.  Against the wrapper as of cc84d5b the
# .c case passes and each of .s and .S fails with
#
#     FAIL -c without -o did not write ./objdir_asm.o into the working directory
#     FAIL the compile overwrote its own source file ../objdir-src/objdir_asm.s
#
# and, because the source is by then an ELF object, the explicit-o compile of
# that same file fails too.  The .S case loses only the object: there the file
# the assembler clobbers is gcc's own preprocessed temporary, not the input.
. "$(dirname "$0")/lib.sh"
rm -rf "${W:?}/objdir" "$W/objdir-src" "$W/objdir-pristine"
mkdir -p $W/objdir $W/objdir-src $W/objdir-pristine
printf '%s\n' \
	'/* Compiled from a DIFFERENT directory than the one it lives in. */' \
	'int objdir_probe(int n) { return n + 1; }' \
	> $W/objdir-src/objdir_src.c
printf '%s\n' \
	'| Assembled from a DIFFERENT directory than the one it lives in.' \
	'	.text' \
	'	.globl	objdir_asm_probe' \
	'objdir_asm_probe:' \
	'	rts' \
	> $W/objdir-src/objdir_asm.s
printf '%s\n' \
	'/* Preprocessed then assembled, from a DIFFERENT directory. */' \
	'#define OBJDIR_CPP_PROBE objdir_cpp_probe' \
	'	.text' \
	'	.globl	OBJDIR_CPP_PROBE' \
	'OBJDIR_CPP_PROBE:' \
	'	rts' \
	> $W/objdir-src/objdir_cpp.S
cp $W/objdir-src/objdir_src.c $W/objdir-src/objdir_asm.s \
	$W/objdir-src/objdir_cpp.S $W/objdir-pristine/
status=0; \
for probe in objdir_src.c objdir_asm.s objdir_cpp.S; do \
	base=${probe%.*}; \
	echo "$probe:"; \
	( cd $W/objdir && \
		"$CC" $CPUFLAGS -O -c ../objdir-src/$probe < /dev/null ) \
		|| { echo "  FAIL -c without -o exited nonzero"; status=1; }; \
	if test -f $W/objdir/$base.o; then \
		echo "  ok   -c without -o wrote ./$base.o into the working directory"; \
	else \
		echo "  FAIL -c without -o did not write ./$base.o into the working directory"; status=1; \
	fi; \
	if test -e $W/objdir-src/$base.o; then \
		echo "  FAIL -c without -o wrote the object next to the source (../objdir-src/$base.o)"; status=1; \
	else \
		echo "  ok   the source directory was left clean"; \
	fi; \
	if cmp -s $W/objdir-src/$probe $W/objdir-pristine/$probe; then \
		echo "  ok   the source file itself is byte-for-byte unchanged"; \
	else \
		echo "  FAIL the compile overwrote its own source file ../objdir-src/$probe"; status=1; \
	fi; \
	rm -f $W/objdir/$base.o; \
	( cd $W/objdir && \
		"$CC" $CPUFLAGS -O -c ../objdir-src/$probe -o ../objdir-src/$base-explicit.o < /dev/null ) \
		|| { echo "  FAIL explicit -o exited nonzero"; status=1; }; \
	if test -f $W/objdir-src/$base-explicit.o; then \
		echo "  ok   explicit -o still honoured verbatim, including a path elsewhere"; \
	else \
		echo "  FAIL explicit -o was not honoured"; status=1; \
	fi; \
done; \
if test -f $W/objdir-src/objdir_cpp-explicit.o && \
	"$NM" $W/objdir-src/objdir_cpp-explicit.o \
	| grep -q ' objdir_cpp_probe$'; then \
	echo "  ok   the .S input went through the preprocessor (macro expanded)"; \
else \
	echo "  FAIL the .S input was assembled without preprocessing"; status=1; \
fi; \
test $status -eq 0 && echo "test-objdir PASS: -c writes ./basename.o for .c/.s/.S, sources untouched, -o unchanged"
exit $status
