/*
 * harness.c -- Linux m68k driver for probe.c (see there).  Built with a
 * Linux m68k gcc at -m68060, so the harness itself never uses an instruction
 * the 68060 lacks, and run under qemu-m68k -cpu m68020 / -cpu m68060.
 *
 * It feeds every probe function edge values and a long pseudo-random stream
 * and folds every result into one checksum, printed as
 *
 *	mul64 checksum XXXXXXXX vectors N
 *
 * Two objects compute the same thing exactly when their checksums match.
 * No libc formatting is used: glibc's number formatting may itself use the
 * 64-bit multiply.
 */

#include <unistd.h>

typedef int (*sfn)(int);
typedef unsigned (*ufn)(unsigned);

#define S(n)	extern int sdiv_##n(int);
#define SM(n)	extern int smod_##n(int);
#define U(n)	extern unsigned udiv_##n(unsigned);
#define UM(n)	extern unsigned umod_##n(unsigned);
S(3) S(7) S(10) S(60) S(m60) S(1000) S(86400) S(1000000) S(641)
SM(3) SM(7) SM(10) SM(m60) SM(86400)
U(3) U(7) U(10) U(60) U(1000) U(86400) U(1000000) U(641) U(big) U(top)
UM(3) UM(7) UM(10) UM(1000) UM(86400)

extern void umul64(unsigned, unsigned, unsigned *);
extern void smul64(int, int, unsigned *);
extern unsigned umul64_idx(unsigned *, int, unsigned);
extern unsigned ccr_mulu(unsigned, unsigned, unsigned, unsigned *);
extern unsigned ccr_muls(unsigned, unsigned, unsigned, unsigned *);
extern unsigned press_u(unsigned *, int);
extern unsigned press_s(int *, int);
extern int sign_after_div(int);

static const sfn sfns[] = {
	sdiv_3, sdiv_7, sdiv_10, sdiv_60, sdiv_m60, sdiv_1000, sdiv_86400,
	sdiv_1000000, sdiv_641, smod_3, smod_7, smod_10, smod_m60, smod_86400,
	sign_after_div,
};
static const ufn ufns[] = {
	udiv_3, udiv_7, udiv_10, udiv_60, udiv_1000, udiv_86400, udiv_1000000,
	udiv_641, udiv_big, udiv_top, umod_3, umod_7, umod_10, umod_1000,
	umod_86400,
};

static const unsigned edges[] = {
	0, 1, 2, 3, 7, 9, 10, 11, 59, 60, 61, 999, 1000, 1001, 86399, 86400,
	86401, 999999, 1000000, 1000001, 640, 641, 642, 0x7fff, 0x8000, 0xffff,
	0x10000, 0x7fffffff, 0x80000000u, 0x80000001u, 0xfffffffbu, 0xfffffffeu,
	0xffffffffu, 0xfffffff6u, 0xffffffc4u, 0xfffeac80u,
};

static unsigned sum = 0x811c9dc5u;
static unsigned long count;

static void
fold(unsigned v)
{
	sum = (sum ^ v) * 0x01000193u;	/* FNV-1a, 32-bit multiply only */
	count++;
}

static unsigned seed = 12345;

static unsigned
rnd(void)
{
	seed = seed * 1103515245u + 12345u;
	return (seed >> 16) | (((seed = seed * 1103515245u + 12345u) >> 16) << 16);
}

static void
one(unsigned x, unsigned y)
{
	unsigned hl[2], v[4], i, c;
	int sv[4];

	for (i = 0; i < sizeof sfns / sizeof sfns[0]; i++)
		fold((unsigned) sfns[i]((int) x));
	for (i = 0; i < sizeof ufns / sizeof ufns[0]; i++)
		fold(ufns[i](x));
	umul64(x, y, hl);
	fold(hl[0]);
	fold(hl[1]);
	smul64((int) x, (int) y, hl);
	fold(hl[0]);
	fold(hl[1]);
	v[0] = x; v[1] = y; v[2] = x ^ y; v[3] = x + y;
	fold(umul64_idx(v, (int) (x & 3), y));
	for (c = 0; c < 32; c += 7) {	/* X N Z V C in, a spread of them */
		fold(ccr_mulu(c, x, y, hl));
		fold(hl[0]);
		fold(hl[1]);
		fold(ccr_muls(c ^ 0x1f, x, y, hl));
		fold(hl[0]);
		fold(hl[1]);
	}
	sv[0] = (int) x; sv[1] = (int) y; sv[2] = (int) (x ^ y);
	sv[3] = (int) (x - y);
	fold(press_u(v, 4));
	fold(press_s(sv, 4));
}

static void
hex(char *p, unsigned v)
{
	int i;

	for (i = 7; i >= 0; i--, v >>= 4)
		p[i] = "0123456789abcdef"[v & 15];
}

int
main(void)
{
	static char line[] = "mul64 checksum 00000000 vectors 00000000\n";
	unsigned i, j, n = sizeof edges / sizeof edges[0];

	for (i = 0; i < n; i++)
		for (j = 0; j < n; j++)
			one(edges[i], edges[j]);
	for (i = 0; i < 20000; i++)
		one(rnd(), rnd());
	hex(line + 15, sum);
	hex(line + 32, (unsigned) count);
	if (write(1, line, sizeof line - 1) != (long) (sizeof line - 1))
		return 1;
	return 0;
}
