# Bootstrap an AMIX cross toolchain on Linux.
#
# A C compiler (GCC 2.7.2.3) and GNU binutils 2.8.1 for m68k-cbm-sysv4: AMIX
# kernel objects, drivers and C programs, linked against an AMIX sysroot.

SHELL := /bin/sh

# Generic names (TARGET, PREFIX, SRCDIR, BUILDDIR, HOST_CC, ...) are plain
# assignments, so a variable of the same name in the environment is ignored;
# override them on the command line (make PREFIX=/opt/amix-cross).  Only the
# AMIX_* names, which nothing else uses, may also come from the environment.

TARGET = m68k-cbm-sysv4
BUILD = i686-pc-linux-gnu
HOST = $(BUILD)
PREFIX = $(HOME)/opt/amix-cross

BINUTILS_VERSION = 2.8.1
GCC_VERSION = 2.7.2.3

GNU_BASE = https://ftp.gnu.org/gnu
BINUTILS_TARBALL := binutils-$(BINUTILS_VERSION).tar.gz
GCC_TARBALL := gcc-$(GCC_VERSION).tar.gz
BINUTILS_URL = $(GNU_BASE)/binutils/$(BINUTILS_TARBALL)
GCC_URL = $(GNU_BASE)/gcc/$(GCC_TARBALL)
BINUTILS_CONFIGURE_EXTRA =
GCC_CONFIGURE_EXTRA =
BINUTILS_DISABLE_DIRS =
# stmp-int-hdrs: gcc's own headers (stdarg.h, stddef.h, varargs.h, limits.h,
# ...), installed in GCC_LIBDIR/include.  cpp searches them after every -I
# directory, and the wrapper puts the sysroot's usr/include first, so they
# only serve a header the AMIX tree does not have.  (float.h needs a run of
# enquire on the target and is the sysroot's.)
GCC_BUILD_TARGETS = xgcc cc1 cccp stmp-int-hdrs

HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
# The AMIX tree the sysroot is made from (usr/include, usr/lib, usr/ccs,
# usr/sys): a checkout of amigaux/amix-system or a copy of an AMIX
# installation.  There is no default; the steps that read it say so.
AMIX_ROOT ?=
need_amix_root = @test -n "$(AMIX_ROOT)" || { echo "AMIX_ROOT is not set: point it at an AMIX tree (usr/include, usr/lib, usr/ccs), e.g. a checkout of amigaux/amix-system" >&2; exit 1; }

DISTDIR = $(HERE)/distfiles
SRCDIR = $(HERE)/src
BUILDDIR = $(HERE)/build

# Recipes delete and recreate trees under these; refuse an empty or root path.
$(foreach v,PREFIX DISTDIR SRCDIR BUILDDIR,$(if $(filter-out /,$(strip $($(v)))),,$(error $(v) must name a directory, not '$($(v))')))

BINUTILS_SRC := $(SRCDIR)/binutils-$(BINUTILS_VERSION)
GCC_SRC := $(SRCDIR)/gcc-$(GCC_VERSION)
BINUTILS_BUILD := $(BUILDDIR)/binutils-$(BINUTILS_VERSION)-$(TARGET)
GCC_BUILD := $(BUILDDIR)/gcc-$(GCC_VERSION)-$(TARGET)

HOST_CC = gcc
HOST_CFLAGS = -O2 -g -std=gnu89 -fcommon -no-pie
# __FILE__ in the binutils and gcc sources (assertion messages) would carry the
# source and build directories into the installed binaries; map them away.
HOST_PATH_CFLAGS := $(shell $(HOST_CC) -ffile-prefix-map=a=b -E -x c /dev/null >/dev/null 2>&1 && \
	echo -ffile-prefix-map=$(SRCDIR)/= -ffile-prefix-map=$(BUILDDIR)/=)
AMIX_MAKEINFO ?= true
override MAKEINFO := $(AMIX_MAKEINFO)
MAKE_JOBS := $(shell nproc 2>/dev/null || echo 1)

CPUFLAGS = -m68020
AMIX_KERNEL_CPPFLAGS ?= -D_KERNEL -DSVR40 -DSVR4
AMIX_KERNEL_INCLUDES ?= -I$(AMIX_ROOT)/usr/include -I$(AMIX_ROOT)/usr/sys -I$(AMIX_ROOT)/usr/sys/amiga/inc
AMIX_KERNEL_CFLAGS ?= -O -traditional -fno-builtin -Dinline=__inline__ -Dvolatile=__volatile__ -Dconst=__const__ $(CPUFLAGS) $(AMIX_KERNEL_CPPFLAGS) $(AMIX_KERNEL_INCLUDES)
SYSROOT = $(PREFIX)/$(TARGET)/sysroot
AMIX_USR_LIB ?= $(AMIX_ROOT)/usr/lib
AMIX_CRT_DIR ?= $(SYSROOT)/usr/ccs/lib
AMIX_CRTS ?= crt1.o crti.o crtn.o
AMIX_USER_CFLAGS ?= -O -traditional -fno-builtin -Dvolatile=__volatile__ -Dconst=__const__ $(CPUFLAGS) -I$(SYSROOT)/usr/include

PATH_FOR_BUILD := $(PREFIX)/bin:$(PATH)
TARGET_CC := $(PREFIX)/bin/$(TARGET)-gcc
TARGET_AS := $(PREFIX)/bin/$(TARGET)-as
TARGET_LD := $(PREFIX)/bin/$(TARGET)-ld
TARGET_AR := $(PREFIX)/bin/$(TARGET)-ar
TARGET_RANLIB := $(PREFIX)/bin/$(TARGET)-ranlib
GCC_LIBDIR := $(PREFIX)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)
GCC_REAL := $(PREFIX)/bin/$(TARGET)-gcc.real

# Stamps of the build and install steps (see "Every build and install step").
STAMPDIR := $(BUILDDIR)/stamps
BINUTILS_STAMP := $(STAMPDIR)/binutils-built
BINUTILS_INSTALL_STAMP := $(STAMPDIR)/binutils-installed
SYSROOT_STAMP := $(STAMPDIR)/sysroot
GCC_STAMP := $(STAMPDIR)/gcc-built
GCC_INSTALL_STAMP := $(STAMPDIR)/gcc-installed
WRAPPER_STAMP := $(STAMPDIR)/wrapper-installed
TARGET_AR_STAMP := $(STAMPDIR)/target-ar-installed
LIBGCC_STAMP := $(STAMPDIR)/libgcc-built
LIBGCC_INSTALL_STAMP := $(STAMPDIR)/libgcc-installed

# Host ar/ranlib the target ar/ranlib wrappers delegate to (see
# amix-ar-wrapper.sh and install-target-ar).
HOST_AR = ar
HOST_RANLIB = ranlib
# Strips the host binaries the toolchain installs (the compiler proper and
# binutils): their debug information carries the build directory's paths.
HOST_STRIP = strip

# Target libgcc: the freestanding libgcc2 helper routines built from the GCC
# 2.7.2.3 source and archived into libgcc.a.  These are the soft-arithmetic
# helpers gcc emits calls to (chiefly the 64-bit DImode integer routines such
# as __udivdi3/__umoddi3/__lshrdi3) plus the DImode<->float conversions.  Every
# routine here is freestanding: it builds and links with no AMIX libc.  Built
# one object per function with -DL<name>, mirroring the stock gcc LIB2FUNCS
# rule, but through the installed wrapper compiler so the SGS->GNU-as fixups are
# applied.  The float->integer conversions are all here: gcc calls
# __fixsfdi, __fixxfdi, __fixunsxfdi and __fixunssfsi for float/long double to
# (unsigned) long long and float to unsigned int, so a library without them
# fails such links.  (They used to be left out because GNU as 2.8.1 rejected
# the SGS fcmp operand order they emit; the compare fixup in fix_asm handles
# that.)
LIBGCC_A := $(GCC_LIBDIR)/libgcc.a
LIBGCC2_BUILD_DIR := $(GCC_BUILD)/amix-libgcc
LIBGCC2_BUILD_CFLAGS = -O2
LIBGCC2_BUILD_INCLUDES := -I$(GCC_BUILD) -I$(GCC_SRC) -I$(GCC_SRC)/config -I$(GCC_SRC)/ginclude
LIBGCC2_FUNCS := _muldi3 _divdi3 _moddi3 _udivdi3 _umoddi3 _negdi2 \
	_lshrdi3 _ashldi3 _ashrdi3 _udiv_w_sdiv _udivmoddi4 _cmpdi2 _ucmpdi2 \
	_floatdidf _floatdisf _floatdixf _fixunsdfdi _fixdfdi _fixunssfdi \
	_fixsfdi _fixxfdi _fixunsxfdi _fixunsdfsi _fixunssfsi _fixunsxfsi \
	__gcc_bcmp _clear_cache _shtab _trampoline

.PHONY: all help deps-hint download extract binutils install-binutils sysroot validate-sysroot check-runtime github-safety-check sysroot-check gcc install-gcc install-gcc-wrapper install-target-ar libgcc install-libgcc env stage check test-hello test-uint64 test-divmod test-float test-fcmp test-cmpm test-bitfield test-lcomm test-objdir test-paths test-options test-link test-dtneeded test-kernel-volatile test-user-volatile test-kernel-object test-mul64 test-mul64-run test-scan060 print-vars clean distclean

# A recipe that fails part-way never leaves its target behind looking finished.
.DELETE_ON_ERROR:

all: $(BINUTILS_INSTALL_STAMP) $(SYSROOT_STAMP) $(GCC_INSTALL_STAMP) $(WRAPPER_STAMP) $(TARGET_AR_STAMP) $(LIBGCC_INSTALL_STAMP) env

help:
	@echo "AMIX cross-toolchain bootstrap"
	@echo ""
	@echo "Common targets:"
	@echo "  make deps-hint       List the build prerequisites (Debian/Ubuntu names)"
	@echo "  make all             Build binutils, import AMIX sysroot, install GCC, write env.sh"
	@echo "  make sysroot         Copy AMIX headers/libs into PREFIX/TARGET/sysroot"
	@echo "  make validate-sysroot Check required user-supplied AMIX runtime files"
	@echo "  make check-runtime   Verify AMIX crt objects needed for Linux-side linking"
	@echo "  make github-safety-check Warn if redistributable repo contains AMIX files"
	@echo "  make install-libgcc  Build and install the target libgcc.a (also part of 'all')"
	@echo "  make test-hello      Try to build and link a runnable AMIX user program"
	@echo "  make env             Write env.sh only"
	@echo "  make stage           Stage the working copy's wrapper over the installed compiler"
	@echo "  make print-vars      Show the selected versions and paths"
	@echo ""
	@echo "Regression gates (each checks the emitted encoding, not just that it assembled;"
	@echo "they run against the staged copy, never the installed wrapper):"
	@echo "  make check          All of the gates below except test-mul64-run"
	@echo "  make test-divmod     Divides use the 32-bit-dividend divsll/divull"
	@echo "  make test-float      Register-to-register fsgldiv/fsglmul are .x; memory forms untouched"
	@echo "  make test-fcmp       Compare order: the fcmp destination is the register the fmul wrote"
	@echo "  make test-bitfield   Bit-field offset/width survive as extension-word bits 10:6 and 4:0"
	@echo "  make test-uint64     64-bit / % >> and float conversions link from libgcc.a"
	@echo "  make test-objdir     '-c' with no '-o' writes ./basename.o, not beside the source"
	@echo "  make test-dtneeded   DT_NEEDED names resolve on the guest, not on the build host"
	@echo "  make test-kernel-volatile  spl()/splx() and MMIO volatile survive AMIX_KERNEL_CFLAGS"
	@echo "  make test-user-volatile    volatile polls and const data survive AMIX_USER_CFLAGS"
	@echo "  make test-kernel-object    stock drivers compile to the native objects' symbol sets"
	@echo "  make test-mul64      No 68060-unimplemented 64-bit multiply; opt-out byte-exact"
	@echo "  make test-mul64-run  The expansion computes what a 68020 does, and runs on a 68060 (qemu)"
	@echo "  make test-scan060    The 68060 instruction scanner's self-test"
	@echo ""
	@echo "Useful overrides:"
	@echo "  make PREFIX=/opt/amix-cross"
	@echo "  make TARGET=m68k-cbm-sysv4"
	@echo "  make CPUFLAGS=-m68030"

# Build prerequisites.  make installs nothing on the host itself.
DEPS_DEBIAN := build-essential make m4 bison flex texinfo curl gzip tar patch file \
	perl python3 bash
DEPS_DEBIAN_TESTS := qemu-user gcc-m68k-linux-gnu

deps-hint:
	@echo "Build prerequisites (Debian/Ubuntu package names):"
	@echo "  $(DEPS_DEBIAN)"
	@echo "make test-mul64-run also needs:"
	@echo "  $(DEPS_DEBIAN_TESTS)"

print-vars:
	@echo "TARGET=$(TARGET)"
	@echo "PREFIX=$(PREFIX)"
	@echo "BINUTILS_VERSION=$(BINUTILS_VERSION)"
	@echo "GCC_VERSION=$(GCC_VERSION)"
	@echo "AMIX_ROOT=$(AMIX_ROOT)"
	@echo "AMIX_KERNEL_CFLAGS=$(AMIX_KERNEL_CFLAGS)"
	@echo "AMIX_USER_CFLAGS=$(AMIX_USER_CFLAGS)"
	@echo "SYSROOT=$(SYSROOT)"
	@echo "AMIX_CRT_DIR=$(AMIX_CRT_DIR)"

download: $(DISTDIR)/$(BINUTILS_TARBALL) $(DISTDIR)/$(GCC_TARBALL)

$(DISTDIR):
	mkdir -p $@

# Every distfile has a pinned SHA-256 in distfiles.sha256.  A download goes to
# a temporary name and gets its real name only once its digest matches, so an
# interrupted or tampered download never looks like a finished one; a distfile
# that is already present is checked again before it is extracted.
DISTFILES_SHA256 := $(HERE)/distfiles.sha256

# $(call check_distfile,FILE,NAME): FILE's SHA-256 must be the one pinned for NAME
define check_distfile
	@f='$(1)'; n='$(2)'; \
	want=$$(awk -v n="$$n" '$$2 == n { print $$1 }' '$(DISTFILES_SHA256)'); \
	test -n "$$want" || { echo "No pinned SHA-256 for $$n in $(DISTFILES_SHA256)" >&2; exit 1; }; \
	got=$$(sha256sum "$$f" | cut -d' ' -f1); \
	test "$$got" = "$$want" || { echo "SHA-256 mismatch for $$f: got $$got, want $$want" >&2; exit 1; }; \
	echo "ok   $$n SHA-256 $$got"
endef

# $(call fetch_distfile,URL): download URL to $@ through $@.tmp
define fetch_distfile
	@f='$@'; rm -f "$${f:?}.tmp"; \
	{ curl -fsSL --retry 3 -o "$$f.tmp" '$(1)' || wget -O "$$f.tmp" '$(1)'; } || { rm -f "$${f:?}.tmp"; exit 1; }
	$(call check_distfile,$@.tmp,$(notdir $@))
	@f='$@'; mv "$${f:?}.tmp" "$$f"
endef

$(DISTDIR)/$(BINUTILS_TARBALL): | $(DISTDIR)
	$(call fetch_distfile,$(BINUTILS_URL))

$(DISTDIR)/$(GCC_TARBALL): | $(DISTDIR)
	$(call fetch_distfile,$(GCC_URL))

extract: $(BINUTILS_SRC)/.amix-cross-extracted $(GCC_SRC)/.amix-cross-extracted

$(SRCDIR):
	mkdir -p $@

# The changes to the GNU sources are patch files under patches/<package>/,
# applied in name order to a freshly extracted tree with no fuzz, so a patch
# that does not apply cleanly stops the build instead of being skipped.
PATCHDIR := $(HERE)/patches
BINUTILS_PATCHES := $(sort $(wildcard $(PATCHDIR)/binutils-$(BINUTILS_VERSION)/*.patch))
GCC_PATCHES := $(sort $(wildcard $(PATCHDIR)/gcc-$(GCC_VERSION)/*.patch))

# binutils 2.8.1 runs config.guess (its configure gets no --build), and its own
# 1997 copy knows no x86_64 host, so the tree gets the copies pinned in config/
# (GNU config.guess 2024-07-27 and config.sub 2024-05-27).  gcc is configured
# with explicit --build, --host and --target, which its own config.sub
# canonicalizes, so its tree keeps the files it ships with.
CONFIGDIR := $(HERE)/config

# $(call apply_patches,TREE,PATCHES)
define apply_patches
	@for p in $(2); do \
		echo "patch $$p"; \
		patch -d '$(1)' -p1 -F0 --forward --batch --no-backup-if-mismatch < "$$p" || exit 1; \
	done
endef

$(BINUTILS_SRC)/.amix-cross-extracted: $(DISTDIR)/$(BINUTILS_TARBALL) $(BINUTILS_PATCHES) $(CONFIGDIR)/config.guess $(CONFIGDIR)/config.sub | $(SRCDIR)
	$(call check_distfile,$(DISTDIR)/$(BINUTILS_TARBALL),$(BINUTILS_TARBALL))
	@s='$(BINUTILS_SRC)'; b='$(BINUTILS_BUILD)'; rm -rf "$${s:?}" "$${b:?}"
	cd $(SRCDIR) && tar -xzf $(DISTDIR)/$(BINUTILS_TARBALL)
	$(call apply_patches,$(BINUTILS_SRC),$(BINUTILS_PATCHES))
	@for f in config.guess config.sub; do \
		chmod u+w '$(BINUTILS_SRC)'/$$f && cp '$(CONFIGDIR)'/$$f '$(BINUTILS_SRC)'/$$f || exit 1; \
	done
	$(MAKE) disable-binutils-dirs TREE=$(BINUTILS_SRC)
	touch $@

$(GCC_SRC)/.amix-cross-extracted: $(DISTDIR)/$(GCC_TARBALL) $(GCC_PATCHES) | $(SRCDIR)
	$(call check_distfile,$(DISTDIR)/$(GCC_TARBALL),$(GCC_TARBALL))
	@s='$(GCC_SRC)'; b='$(GCC_BUILD)'; rm -rf "$${s:?}" "$${b:?}"
	cd $(SRCDIR) && tar -xzf $(DISTDIR)/$(GCC_TARBALL)
	$(call apply_patches,$(GCC_SRC),$(GCC_PATCHES))
	touch $@

disable-binutils-dirs:
	@test -n "$(TREE)" || { echo "TREE is required"; exit 1; }
	@for dir in $(BINUTILS_DISABLE_DIRS); do \
		if test -d "$(TREE)/$$dir" && test ! -d "$(TREE)/$$dir.disabled"; then \
			t='$(TREE)'; mv "$${t:?}/$${dir:?}" "$$t/$$dir.disabled"; \
			echo "Disabled binutils subdir $$dir"; \
		fi; \
	done

$(BUILDDIR):
	mkdir -p $@

# Every build and install step is a file target, ending in a stamp under
# $(STAMPDIR), and depends only on files: nothing is reconfigured or
# reinstalled unless an input changed, and "make -j" runs the steps in a valid
# order.  The phony names below (binutils, install-gcc, ...) are aliases for
# the stamps.  The stamps record what was installed into PREFIX, so after
# changing PREFIX run "make clean" first.

$(STAMPDIR):
	mkdir -p $@

$(BINUTILS_BUILD)/config.status: $(BINUTILS_SRC)/.amix-cross-extracted | $(BUILDDIR)
	mkdir -p $(BINUTILS_BUILD)
	cd $(BINUTILS_BUILD) && CC="$(HOST_CC)" CFLAGS="$(HOST_CFLAGS) $(HOST_PATH_CFLAGS)" $(BINUTILS_SRC)/configure \
		--target=$(TARGET) \
		--prefix=$(PREFIX) \
		--disable-nls \
		$(BINUTILS_CONFIGURE_EXTRA)

$(BINUTILS_STAMP): $(BINUTILS_BUILD)/config.status | $(STAMPDIR)
	$(MAKE) -C $(BINUTILS_BUILD) -j$(MAKE_JOBS) \
		CC="$(HOST_CC)" \
		CFLAGS="$(HOST_CFLAGS) $(HOST_PATH_CFLAGS)" \
		MAKEINFO="$(AMIX_MAKEINFO)"
	touch $@

$(BINUTILS_INSTALL_STAMP): $(BINUTILS_STAMP)
	$(MAKE) -C $(BINUTILS_BUILD) install \
		CC="$(HOST_CC)" \
		CFLAGS="$(HOST_CFLAGS) $(HOST_PATH_CFLAGS)" \
		MAKEINFO="$(AMIX_MAKEINFO)"
	@for f in $(PREFIX)/bin/$(TARGET)-* $(PREFIX)/$(TARGET)/bin/*; do \
		test "$$(head -c 4 "$$f" | od -An -tx1 | tr -d ' ')" = 7f454c46 || continue; \
		chmod u+w "$$f" && $(HOST_STRIP) "$$f" || exit 1; \
	done
	touch $@

binutils: $(BINUTILS_STAMP)
install-binutils: $(BINUTILS_INSTALL_STAMP)

# The stock files copied into the sysroot are made read-only once copied, so
# a stray link step (for example an ld option that takes the next argument as
# a map-file name) cannot overwrite libc.so.1 or a header in place.  Directories
# stay writable so extra libraries can still be added.  Regenerating lifts the
# write protection first, because cp cannot overwrite a read-only file.
# "make sysroot" always copies again; the build itself copies once.
define copy_sysroot
	mkdir -p $(SYSROOT)/usr
	chmod -R u+w $(SYSROOT)/usr
	test -n "$(AMIX_ROOT)" && test -d "$(AMIX_ROOT)/usr/include"
	cp -R "$(AMIX_ROOT)/usr/include" "$(SYSROOT)/usr/"
	if test -d "$(AMIX_ROOT)/usr/sys"; then cp -R "$(AMIX_ROOT)/usr/sys" "$(SYSROOT)/usr/"; fi
	if test -d "$(AMIX_ROOT)/usr/ccs"; then cp -R "$(AMIX_ROOT)/usr/ccs" "$(SYSROOT)/usr/"; fi
	if test -d "$(AMIX_USR_LIB)"; then mkdir -p "$(SYSROOT)/usr/lib"; cp -R "$(AMIX_USR_LIB)"/. "$(SYSROOT)/usr/lib/"; fi
	@for f in libc.so.1 ld.so.1; do \
		if test -f "$(AMIX_USR_LIB)/$$f"; then \
			tmp="$(SYSROOT)/usr/lib/.$$f.tmp"; \
			cp "$(AMIX_USR_LIB)/$$f" "$$tmp"; \
			test -s "$$tmp"; \
			mv "$${tmp:?}" "$(SYSROOT)/usr/lib/$${f:?}"; \
		fi; \
	done
	@for d in include sys ccs; do \
		if test -d "$(AMIX_ROOT)/usr/$$d"; then \
			(cd "$(AMIX_ROOT)/usr" && find "$$d" -type f) | \
				while read -r f; do chmod a-w "$(SYSROOT)/usr/$$f"; done; \
		fi; \
	done
	@if test -d "$(AMIX_USR_LIB)"; then \
		(cd "$(AMIX_USR_LIB)" && find . -type f) | \
			while read -r f; do chmod a-w "$(SYSROOT)/usr/lib/$$f"; done; \
	fi
	@echo "Stock sysroot files are now read-only"
endef

$(SYSROOT_STAMP): | $(STAMPDIR)
	$(need_amix_root)
	$(copy_sysroot)
	touch $@

sysroot: | $(STAMPDIR)
	$(need_amix_root)
	$(copy_sysroot)
	touch $(SYSROOT_STAMP)

# Refuse to run when the sysroot libc is not an ELF shared object: a clobbered
# libc.so.1 makes every dynamic link fail with "file format not recognized".
# The ELF type at offset 16 must be ET_DYN (big-endian 0x0003).
sysroot-check:
	@f="$(SYSROOT)/usr/lib/libc.so.1"; \
	magic=$$(od -An -tx1 -N18 "$$f" 2>/dev/null | tr -d ' \n'); \
	case "$$magic" in \
		7f454c46*0003) echo "ok   $$f is an ELF shared object" ;; \
		*) echo "ERROR: $$f is not an ELF shared object; run make sysroot" >&2; exit 1 ;; \
	esac

validate-sysroot: $(SYSROOT_STAMP)
	@missing=0; \
	for f in \
		usr/include/stdio.h \
		usr/include/sys/types.h \
		usr/lib/libc.so.1 \
		usr/lib/ld.so.1 \
		usr/ccs/lib/crt1.o \
		usr/ccs/lib/crti.o \
		usr/ccs/lib/crtn.o; do \
		if test ! -f "$(SYSROOT)/$$f"; then \
			echo "Missing $(SYSROOT)/$$f"; \
			missing=1; \
		elif test ! -s "$(SYSROOT)/$$f"; then \
			echo "Empty or truncated $(SYSROOT)/$$f"; \
			missing=1; \
		fi; \
	done; \
	test $$missing -eq 0

check-runtime: validate-sysroot
	@missing=0; \
	for f in $(AMIX_CRTS); do \
		if test ! -f "$(AMIX_CRT_DIR)/$$f" && test ! -f "$(SYSROOT)/usr/ccs/lib/$$f" && test ! -f "$(SYSROOT)/usr/lib/$$f"; then \
			echo "Missing AMIX startup object $$f. Copy it from AMIX, usually /usr/ccs/lib or /usr/lib, then set AMIX_CRT_DIR."; \
			missing=1; \
		fi; \
	done; \
	test $$missing -eq 0

# AMIX system files belong in the sysroot, never in this repository: fail if
# git tracks (or is about to commit) anything that looks like one.
github-safety-check:
	@files=$$(cd "$(HERE)" && { git ls-files 2>/dev/null; git diff --cached --name-only 2>/dev/null; } | \
		grep -E '(^|/)(sysroot|usr/include|usr/lib|usr/ccs)/|(^|/)(libc\.so\.1|ld\.so\.1|crt[0-9a-z]*\.o|values-X[act]\.o)$$' | sort -u); \
	if test -n "$$files"; then \
		echo "AMIX system files are tracked by git in $(HERE):" >&2; \
		printf '  %s\n' $$files >&2; exit 1; \
	fi; \
	echo "ok   no AMIX system file is tracked in $(HERE)"

# gcc's own build needs the installed binutils (configure looks for the GNU
# assembler and linker under PREFIX), not the sysroot.
$(GCC_BUILD)/config.status: $(GCC_SRC)/.amix-cross-extracted $(BINUTILS_INSTALL_STAMP) | $(BUILDDIR)
	mkdir -p $(GCC_BUILD)
	cd $(GCC_BUILD) && PATH="$(PATH_FOR_BUILD)" CC="$(HOST_CC)" CFLAGS="$(HOST_CFLAGS) $(HOST_PATH_CFLAGS)" $(GCC_SRC)/configure \
		--build=$(BUILD) \
		--host=$(HOST) \
		--target=$(TARGET) \
		--prefix=$(PREFIX) \
		--with-gnu-as \
		--with-gnu-ld \
		$(GCC_CONFIGURE_EXTRA)

$(GCC_STAMP): $(GCC_BUILD)/config.status | $(STAMPDIR)
	@if test ! -f "$(GCC_BUILD)/libgcc1.a" && test ! -f "$(GCC_BUILD)/libgcc1.cross"; then \
		echo "Creating empty target libgcc1.a for compile-only bootstrap"; \
		cd "$(GCC_BUILD)" && "$(TARGET_AR)" rc libgcc1.a; \
		"$(TARGET_RANLIB)" "$(GCC_BUILD)/libgcc1.a" || true; \
	fi
	PATH="$(PATH_FOR_BUILD)" $(MAKE) -C $(GCC_BUILD) -j$(MAKE_JOBS) \
		LANGUAGES=c \
		CC="$(HOST_CC)" \
		CFLAGS="$(HOST_CFLAGS) $(HOST_PATH_CFLAGS)" \
		MAKEINFO="$(AMIX_MAKEINFO)" \
		$(GCC_BUILD_TARGETS)
	touch $@

# Installs the compiler proper: the gcc driver as $(TARGET)-gcc.real, cc1,
# cpp and the specs.  $(TARGET)-gcc is the wrapper, and only the wrapper step
# writes it, so no step leaves the bare driver under the wrapper's name.
$(GCC_INSTALL_STAMP): $(GCC_STAMP)
	mkdir -p $(PREFIX)/bin $(GCC_LIBDIR)
	cp $(GCC_BUILD)/xgcc $(GCC_REAL)
	cp $(GCC_BUILD)/cc1 $(GCC_LIBDIR)/cc1
	cp $(GCC_BUILD)/cccp $(GCC_LIBDIR)/cpp
	mkdir -p $(GCC_LIBDIR)/include
	cp $(GCC_BUILD)/include/*.h $(GCC_LIBDIR)/include/
	$(HOST_STRIP) $(GCC_REAL) $(GCC_LIBDIR)/cc1 $(GCC_LIBDIR)/cpp
	PATH="$(PATH_FOR_BUILD)" $(GCC_BUILD)/xgcc -B$(GCC_BUILD)/ -dumpspecs > $(GCC_LIBDIR)/specs.amix-tmp
	$(call fix_specs,$(GCC_LIBDIR)/specs.amix-tmp,$(GCC_LIBDIR)/specs)
	@t='$(GCC_LIBDIR)/specs.amix-tmp'; rm -f "$${t:?}"
	chmod 755 $(GCC_REAL) $(GCC_LIBDIR)/cc1 $(GCC_LIBDIR)/cpp
	touch $@

gcc: $(GCC_STAMP)
install-gcc: $(GCC_INSTALL_STAMP)

# The specs, corrected: the assembler gets the -m680x0 flags, so the assembler
# wrapper assembles for the CPU the code was compiled for.
# $(call fix_specs,IN,OUT)
define fix_specs
	sed '/^\*asm:$$/{n;/%{m68\*}/!s/^/%{m68*} %{mc68*} /;}' $(1) > $(2)
endef

# $(call install_gcc_wrapper,PREFIX): the wrapper, the 68060 scanner and the
# assembler wrapper the real driver runs, with fix_asm copied into it from
# amix-gcc-wrapper.sh (which keeps the one definition).
define install_gcc_wrapper
	sed 's/@TARGET@/$(TARGET)/g' $(HERE)/amix-gcc-wrapper.sh > $(1)/bin/$(TARGET)-gcc
	chmod 755 $(1)/bin/$(TARGET)-gcc
	sed 's/@TARGET@/$(TARGET)/g' $(HERE)/amix-scan060.py > $(1)/bin/$(TARGET)-scan060
	chmod 755 $(1)/bin/$(TARGET)-scan060
	sed -n '/^fix_asm()/,/^}$$/p' $(HERE)/amix-gcc-wrapper.sh > $(1)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)/as.fix_asm
	sed -e 's/@TARGET@/$(TARGET)/g' -e '/^@FIX_ASM@$$/{r $(1)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)/as.fix_asm' -e 'd;}' \
		$(HERE)/amix-as-wrapper.sh > $(1)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)/as
	@f='$(1)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)/as.fix_asm'; rm -f "$${f:?}"
	grep -q '^fix_asm()' $(1)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)/as
	chmod 755 $(1)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)/as
endef

$(WRAPPER_STAMP): $(GCC_INSTALL_STAMP) $(HERE)/amix-gcc-wrapper.sh $(HERE)/amix-as-wrapper.sh $(HERE)/amix-scan060.py
	$(call install_gcc_wrapper,$(PREFIX))
	touch $@

install-gcc-wrapper: $(WRAPPER_STAMP)

# Replace the fortify-aborting binutils 2.8.1 ar/ranlib with thin wrappers that
# delegate to the host ar/ranlib (see amix-ar-wrapper.sh for the rationale).
# The shipped ar/ranlib are hardlinked to $(TARGET)/bin/ar etc., so remove the
# target path first to break the link before writing the wrapper in its place.
# It depends on the binutils install, which writes the broken ar/ranlib, so it
# always runs after it.
$(TARGET_AR_STAMP): $(BINUTILS_INSTALL_STAMP) $(HERE)/amix-ar-wrapper.sh
	@hostar="$$(command -v $(HOST_AR) 2>/dev/null)"; \
	hostranlib="$$(command -v $(HOST_RANLIB) 2>/dev/null)"; \
	test -n "$$hostar" || { echo "Host '$(HOST_AR)' not found in PATH"; exit 1; }; \
	test -n "$$hostranlib" || { echo "Host '$(HOST_RANLIB)' not found in PATH"; exit 1; }; \
	mkdir -p "$(PREFIX)/bin"; \
	for tool in ar ranlib; do \
		dest="$(PREFIX)/bin/$(TARGET)-$$tool"; \
		sed -e 's/@TARGET@/$(TARGET)/g' \
		    -e "s|@HOST_AR@|$$hostar|g" \
		    -e "s|@HOST_RANLIB@|$$hostranlib|g" \
		    "$(HERE)/amix-ar-wrapper.sh" > "$$dest.amix-tmp"; \
		rm -f "$${dest:?}"; \
		mv "$${dest:?}.amix-tmp" "$$dest"; \
		chmod 755 "$$dest"; \
		echo "Installed $$dest (delegates to host $$tool)"; \
	done
	touch $@

install-target-ar: $(TARGET_AR_STAMP)

# Build libgcc.a from the freestanding libgcc2 helper routines.  One object per
# function (-DL<name>), compiled through the installed wrapper compiler so the
# assembler fixups apply, then archived with the target ar wrapper.  The
# wrapper puts the sysroot headers first, so the sysroot is copied before.
$(LIBGCC_STAMP): $(WRAPPER_STAMP) $(TARGET_AR_STAMP) $(SYSROOT_STAMP)
	@d='$(LIBGCC2_BUILD_DIR)'; rm -rf "$${d:?}"
	mkdir -p $(LIBGCC2_BUILD_DIR)
	@set -e; objs=""; \
	for name in $(LIBGCC2_FUNCS); do \
		echo "libgcc2: $$name"; \
		PATH="$(PATH_FOR_BUILD)" "$(TARGET_CC)" $(LIBGCC2_BUILD_CFLAGS) $(LIBGCC2_BUILD_INCLUDES) \
			-DL$$name -c "$(GCC_SRC)/libgcc2.c" -o "$(LIBGCC2_BUILD_DIR)/$$name.o"; \
		objs="$$objs $$name.o"; \
	done; \
	cd "$(LIBGCC2_BUILD_DIR)" && rm -f libgcc.a && \
		"$(TARGET_AR)" rc libgcc.a $$objs && \
		"$(TARGET_RANLIB)" libgcc.a
	@echo "Built $(LIBGCC2_BUILD_DIR)/libgcc.a"
	touch $@

$(LIBGCC_INSTALL_STAMP): $(LIBGCC_STAMP)
	mkdir -p $(GCC_LIBDIR)
	cp $(LIBGCC2_BUILD_DIR)/libgcc.a $(LIBGCC_A)
	"$(TARGET_RANLIB)" $(LIBGCC_A)
	@echo "Installed $(LIBGCC_A)"
	touch $@

libgcc: $(LIBGCC_STAMP)
install-libgcc: $(LIBGCC_INSTALL_STAMP)

env:
	$(need_amix_root)
	@mkdir -p $(BUILDDIR)
	@printf '%s\n' '# Source this file before cross-compiling for AMIX.' > $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_CROSS_TARGET="$(TARGET)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_CROSS_PREFIX="$(PREFIX)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export PATH="$(PREFIX)/bin:$$PATH"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_ROOT="$(AMIX_ROOT)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_SYSROOT="$(SYSROOT)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_CRT_DIR="$(AMIX_CRT_DIR)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_KERNEL_CFLAGS="$(AMIX_KERNEL_CFLAGS)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_USER_CFLAGS="$(AMIX_USER_CFLAGS)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'case "$$(od -An -tx1 -N18 "$$AMIX_SYSROOT/usr/lib/libc.so.1" 2>/dev/null | tr -d " \\n")" in 7f454c46*0003) ;; *) echo "env.sh: $$AMIX_SYSROOT/usr/lib/libc.so.1 is not an ELF shared object; run make sysroot" >&2; return 1 2>/dev/null || exit 1 ;; esac' >> $(BUILDDIR)/env.sh
	@echo "Wrote $(BUILDDIR)/env.sh"

test-hello: all check-runtime sysroot-check
	mkdir -p $(BUILDDIR)/test
	printf '%s\n' '#include <stdio.h>' 'int main(void) { puts("hello from AMIX cross"); return 0; }' > $(BUILDDIR)/test/hello.c
	AMIX_SYSROOT="$(SYSROOT)" AMIX_CRT_DIR="$(AMIX_CRT_DIR)" $(TARGET_CC) $(CPUFLAGS) -o $(BUILDDIR)/test/hello $(BUILDDIR)/test/hello.c
	file $(BUILDDIR)/test/hello

# The regression gates.  Each is a script in tests/ that checks the emitted
# encoding, not merely that the file assembled.  They run against a staged
# copy of the toolchain in $(STAGE): the working copy's wrapper and scanner,
# with links to the installed compiler, binutils and libgcc.a, so testing an
# edit never changes the compiler in PREFIX that other builds use.  "make all"
# first; "make check" runs every gate that needs no extra tools.
STAGE := $(BUILDDIR)/stage
STAGE_LIBDIR := $(STAGE)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)
STAGE_CC := $(STAGE)/bin/$(TARGET)-gcc
TEST_ENV = CC='$(STAGE_CC)' CPUFLAGS='$(CPUFLAGS)' SYSROOT='$(SYSROOT)' \
	AMIX_SYSROOT='$(SYSROOT)' AMIX_CRT_DIR='$(AMIX_CRT_DIR)' AMIX_ROOT='$(AMIX_ROOT)' \
	AMIX_KERNEL_CFLAGS='$(AMIX_KERNEL_CFLAGS)' AMIX_USER_CFLAGS='$(AMIX_USER_CFLAGS)'
CHECK_GATES := divmod float fcmp cmpm bitfield lcomm objdir paths options link uint64 dtneeded kernel-volatile \
	user-volatile kernel-object mul64 scan060

stage: sysroot-check
	@test -x "$(GCC_REAL)" || { echo "Missing $(GCC_REAL); run 'make all' first" >&2; exit 1; }
	@s='$(STAGE)'; rm -rf "$${s:?}"
	@mkdir -p $(STAGE)/bin $(STAGE_LIBDIR)
	@for f in $(PREFIX)/bin/$(TARGET)-*; do ln -s "$$f" $(STAGE)/bin/ || exit 1; done
	@for f in $(GCC_LIBDIR)/*; do ln -s "$$f" $(STAGE_LIBDIR)/ || exit 1; done
	@ln -s $(PREFIX)/$(TARGET) $(STAGE)/$(TARGET)
	@rm -f $(STAGE)/bin/$(TARGET)-gcc $(STAGE)/bin/$(TARGET)-scan060 $(STAGE_LIBDIR)/as $(STAGE_LIBDIR)/specs
	$(call fix_specs,$(GCC_LIBDIR)/specs,$(STAGE_LIBDIR)/specs)
	$(call install_gcc_wrapper,$(STAGE))

$(addprefix test-,divmod float fcmp cmpm bitfield lcomm objdir paths options link uint64 dtneeded kernel-volatile user-volatile kernel-object): test-%: stage
	$(TEST_ENV) W='$(BUILDDIR)/test/$*' sh $(HERE)/tests/$*.sh

test-dtneeded: check-runtime

# The 68060 multiply expansion: test-mul64 checks the encodings, test-mul64-run
# runs the probe under qemu-m68k as a 68020 and a 68060 (needs qemu-m68k and a
# Linux m68k gcc, LINUX_M68K_CC, default m68k-linux-gnu-gcc).
test-mul64: stage
	$(TEST_ENV) sh $(HERE)/tests/mul64/check.sh $(STAGE_CC) $(BUILDDIR)/test/mul64

test-mul64-run: stage
	$(TEST_ENV) sh $(HERE)/tests/mul64/run.sh $(STAGE_CC) $(BUILDDIR)/test/mul64-run

# The scanner's own self-test: known encodings assembled by this toolchain,
# including a switch table whose entries decode as movep, both in an object and
# in a stripped executable linked at 0x80000000 like an AMIX program.
test-scan060: stage
	$(STAGE)/bin/$(TARGET)-scan060 --self-test

check: $(addprefix test-,$(CHECK_GATES))
	@echo "make check: all $(words $(CHECK_GATES)) gates passed"

clean:
	@d='$(BUILDDIR)'; rm -rf "$${d:?}"

distclean: clean
	@s='$(SRCDIR)'; d='$(DISTDIR)'; rm -rf "$${s:?}" "$${d:?}"
