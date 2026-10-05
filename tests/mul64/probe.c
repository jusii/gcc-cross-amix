/*
 * probe.c -- code that makes gcc 2.7.2.3 emit the 64-bit-product multiply
 * "muls.l/mulu.l <ea>,%dH:%dL" (divide/modulo by a constant, (u64)a*b), in
 * every shape the wrapper's 68060 expansion has to get right.
 *
 * It is compiled for AMIX by the cross wrapper and linked into harness.c, a
 * Linux m68k program, so that qemu-m68k can run the very same object on a
 * 68020 (which implements the 64-bit form) and a 68060 (which raises vector
 * 61 for it).  Only plain C calls with int/unsigned/pointer arguments cross
 * between the two ABIs; both pass them on the stack and return in %d0.
 */

#define SDIV(n, d)	int sdiv_##n(int x) { return x / (d); }
#define SMOD(n, d)	int smod_##n(int x) { return x % (d); }
#define UDIV(n, d)	unsigned udiv_##n(unsigned x) { return x / (d); }
#define UMOD(n, d)	unsigned umod_##n(unsigned x) { return x % (d); }

SDIV(3, 3)  SDIV(7, 7)  SDIV(10, 10)  SDIV(60, 60)  SDIV(m60, -60)
SDIV(1000, 1000)  SDIV(86400, 86400)  SDIV(1000000, 1000000)  SDIV(641, 641)
SMOD(3, 3)  SMOD(7, 7)  SMOD(10, 10)  SMOD(m60, -60)  SMOD(86400, 86400)
UDIV(3, 3)  UDIV(7, 7)  UDIV(10, 10)  UDIV(60, 60)  UDIV(1000, 1000)
UDIV(86400, 86400)  UDIV(1000000, 1000000)  UDIV(641, 641)
UDIV(big, 0x80000001u)  UDIV(top, 0xfffffffbu)
UMOD(3, 3)  UMOD(7, 7)  UMOD(10, 10)  UMOD(1000, 1000)  UMOD(86400, 86400)

/* 32x32 -> 64 products, operand in a register, in memory and indexed. */
void
umul64(unsigned a, unsigned b, unsigned *hl)
{
	unsigned long long p = (unsigned long long) a * b;

	hl[0] = (unsigned) (p >> 32);
	hl[1] = (unsigned) p;
}

void
smul64(int a, int b, unsigned *hl)
{
	long long p = (long long) a * b;

	hl[0] = (unsigned) (p >> 32);
	hl[1] = (unsigned) p;
}

unsigned
umul64_idx(unsigned *v, int i, unsigned b)
{
	unsigned long long p = (unsigned long long) v[i & 3] * b;

	return (unsigned) (p >> 32) ^ (unsigned) p;
}

/*
 * The flags: load a chosen CCR (X N Z V C), multiply, read the CCR back.
 * The 64-bit multiply sets N from bit 63, Z from the whole product, clears
 * V and C and leaves X alone; the expansion has to do the same.
 */
unsigned
ccr_mulu(unsigned ccrin, unsigned a, unsigned b, unsigned *hl)
{
	unsigned hi, lo, c;

	__asm__ __volatile__("mov.w %4,%%cc\n\tmulu.l %5,%0:%1\n\tmov.w %%cc,%2"
	    : "=&d" (hi), "=d" (lo), "=&d" (c) : "1" (a), "d" (ccrin), "d" (b));
	hl[0] = hi;
	hl[1] = lo;
	return c & 0x1f;
}

unsigned
ccr_muls(unsigned ccrin, unsigned a, unsigned b, unsigned *hl)
{
	unsigned hi, lo, c;

	__asm__ __volatile__("mov.w %4,%%cc\n\tmuls.l %5,%0:%1\n\tmov.w %%cc,%2"
	    : "=&d" (hi), "=d" (lo), "=&d" (c) : "1" (a), "d" (ccrin), "m" (b));
	hl[0] = hi;
	hl[1] = lo;
	return c & 0x1f;
}

/*
 * Register pressure: eight accumulators live across every divide, so the
 * multiply's %dH:%dL and its neighbours land in all of %d0-%d7.
 */
unsigned
press_u(unsigned *v, int n)
{
	unsigned a = 0, b = 1, c = 2, d = 3, e = 4, f = 5, g = 6, h = 7;
	int i;

	for (i = 0; i < n; i++) {
		unsigned x = v[i];

		a += x / 10;
		b ^= x % 7;
		c += x / 1000;
		d ^= (x / 3) << 1;
		e += x % 86400;
		f ^= x / 641;
		g += (x % 10) * 3;
		h ^= x / 60;
	}
	return a ^ (b << 1) ^ (c << 2) ^ (d << 3) ^ (e << 4) ^ (f << 5)
	    ^ (g << 6) ^ (h << 7);
}

unsigned
press_s(int *v, int n)
{
	int a = 0, b = 1, c = 2, d = 3, e = 4, f = 5, g = 6, h = 7;
	int i;

	for (i = 0; i < n; i++) {
		int x = v[i];

		a += x / 10;
		b ^= x % 7;
		c += x / -1000;
		d ^= (x / 3) << 1;
		e += x % 86400;
		f ^= x / 641;
		g += (x % 10) * 3;
		h ^= x / 60;
	}
	return a ^ (b << 1) ^ (c << 2) ^ (d << 3) ^ (e << 4) ^ (f << 5)
	    ^ (g << 6) ^ (h << 7);
}

/* A divide feeding a branch: the compare after it must see real flags. */
int
sign_after_div(int x)
{
	if (x / 10 < 0)
		return -1;
	if (x / 10 == 0)
		return 0;
	return 1;
}
