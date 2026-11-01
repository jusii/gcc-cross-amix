# Licensing status

This repository has **no licence file yet**. Its code comes from three
authors, and until each of them grants a licence for the lines they wrote,
those lines are all rights reserved. This note records who wrote what, so that
a grant can be requested from each author (or a part rewritten). It changes
nothing about anyone's rights; it is only a map.

The counts are `git blame` at commit `d9cba56` (lines surviving in each file),
plus what blame cannot see: code that was moved from one file into another,
where blame names the person who moved it.

## Authors

| Author | Commits | Surviving lines |
|---|---|---|
| Ignacio Soriano (isoriano1968) | `1ee3b7b` (2026-06-14, the initial bootstrap) through `7ecf84a`, and the pull-request merges | 527 |
| Antti Sokero (asokero) | `ec36b07` (2026-08-28, merged in `048e85c`) | 19 |
| Jussi Alanärä (Jusii) | every other commit | the rest |

## By file

| File | Lines | Ignacio Soriano | Antti Sokero | Jussi Alanärä |
|---|---:|---:|---:|---:|
| `Makefile` | 641 | 202 | 0 | 439 |
| `README.md` | 651 | 201 | 0 | 450 |
| `amix-gcc-wrapper.sh` | 741 | 103 | 19 | 619 |
| `.gitignore` | 17 | 17 | 0 | 0 |
| `.gitattributes` | 6 | 4 | 0 | 2 |
| `amix-as-wrapper.sh` | 118 | see below | see below | 118 |
| `patches/binutils-2.8.1/01-*.patch`, `02-*.patch`, `patches/gcc-2.7.2.3/01-*.patch`, `02-*.patch` | 109 | see below | 0 | 109 |
| `amix-ar-wrapper.sh`, `amix-scan060.py` | 496 | 0 | 0 | 496 |
| `tests/` (every gate, the mul64 probe and harness) | 1490 | 0 | 0 | 1490 |
| `patches/gcc-2.7.2.3/03-m68060.patch` | 161 | 0 | 0 | 161 |
| `CHANGELOG.md`, `distfiles.sha256`, this file | | 0 | 0 | all |

### What Ignacio Soriano's lines are

- `Makefile`: the skeleton -- the version and path variables, the download,
  extract, configure, build and install rules for binutils and gcc, the
  sysroot copy and its validation targets, the `env.sh` writer.
- `README.md`: the structure and much of the build and usage text.
- `amix-gcc-wrapper.sh`: the frame -- tool and sysroot variables, the
  temporary-file list and its cleanup, the parenthesis-aware operand splitter
  in fix_asm rule 6 (`split_operands`) and the compare swap around it, the
  outline of `resolve_lib`, the outline of the argument loop and the link
  step.
- `.gitignore`, most of `.gitattributes`.
- The four patch files named above reproduce, as patches, the source edits
  his Makefile made with sed and perl in `1ee3b7b` (the `strerror` fallback in
  `cccp.c` and `gcc.c`, the `gcc2_compiled` label, the `ld` emulation entry for
  `m68k-*-sysv4`, the `md_relax_table` declaration in gas). Blame shows them
  as moved.

### What Antti Sokero's lines are

From `ec36b07`: fix_asm rules 7 to 10 (`f[sd]xxx` with an FPU source to `.x`,
`fdmov` to `fdmove`, sized `fmovm` to `fmovem`, `mov &N,%dN` to `mov.l`),
19 lines in `amix-gcc-wrapper.sh`. The same commit made the assembler follow
the compile's `-m68030`/`-m68040`/`-m68060`; that selection now lives in
`amix-as-wrapper.sh` (moved there and extended), where blame does not show it.

## Third-party material

- GNU binutils 2.8.1 and GCC 2.7.2.3 are not in this repository; the Makefile
  downloads them (pinned SHA-256 in `distfiles.sha256`). Both are GPL-2.0 or
  later.
- `patches/` holds changes to those sources and is under their licence,
  GPL-2.0 or later, whoever wrote the change.
- `config/config.guess` and `config/config.sub` are unchanged copies of GNU
  `config.guess` (2024-07-27) and `config.sub` (2024-05-27): GPL-3.0 or later
  with the Autoconf exception, as their headers say.

## What a grant would cover

A written permission from Ignacio Soriano for his lines and from Antti Sokero
for `ec36b07`, under the licence chosen for the repository, would let a
`LICENSE` file cover everything outside `patches/` and `config/`. The
alternative is to rewrite their lines; most of the original wrapper and
Makefile has been replaced already, so what remains is listed above.
