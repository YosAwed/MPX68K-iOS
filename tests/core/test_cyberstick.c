/* CYBER STICK (analog mode) on joystick port 1: the report as Sharp's driver
 * algorithm reads it at different CPU clocks and polling speeds, the idle lines,
 * a restarted report, and the plain digital joystick when the CYBER STICK is off.
 */
#include <assert.h>
#include <stdio.h>
#include "common.h"
#include "joystick.h"

void X68000_Joystick_Set(BYTE num, BYTE data);   /* joystick.c, used by the app */

/* Emulated CPU: cycles of the running slice; the "main loop" below closes slices. */
static int in_slice = 0;
int WinX68k_CyclesInSlice(void) { return in_slice; }

static void run(int cycles)
{
	in_slice += cycles;
	if (in_slice >= 1000) {         /* a slice ends now and then, mid-report too */
		Joystick_CPUSliceDone(in_slice);
		in_slice = 0;
	}
}

static int poll_cycles = 40;           /* one polling loop iteration */
static long reads = 0;

static BYTE port(void)
{
	run(poll_cycles);
	++reads;
	return Joystick_Read(0);
}

static void req(int high) { Joystick_Write(0, high ? 0xff : 0x00); }

#define LH(v)  (((v) >> 5) & 1)
#define ACK(v) (((v) >> 6) & 1)

/* Polls until (port & mask) == want; fails after a generous timeout. */
static BYTE wait_for(BYTE mask, BYTE want)
{
	for (int i = 0; i < 10000; ++i) {
		BYTE v = port();
		if ((v & mask) == want) return v;
	}
	fprintf(stderr, "timeout waiting for %02x/%02x\n", mask, want);
	assert(0);
	return 0;
}

/* Sharp's X68000 driver: falling edge, then per pair of nibbles wait L/H low,
 * ACK low, read; wait L/H high, ACK low, read; raise REQ after eight. */
static void read_sharp(BYTE nib[12])
{
	req(1);
	run(100);
	req(0);
	for (int i = 0; i < 12; i += 2) {
		wait_for(0x20, 0x00);
		nib[i] = wait_for(0x40, 0x00) & 0x0f;
		wait_for(0x20, 0x20);
		nib[i + 1] = wait_for(0x40, 0x00) & 0x0f;
		if (i + 2 == 8) req(1);
	}
	req(1);
}

static void check_report(const BYTE *n, int count, BYTE y, BYTE x, BYTE z, BYTE ab)
{
	/* ab: bit 1 = A released, bit 0 = B released (active low like the stick) */
	assert(n[0] == (BYTE)((ab << 2) | 0x03));
	assert(n[1] == 0x0f);
	assert(((n[2] << 4) | n[6]) == y);
	assert(((n[3] << 4) | n[7]) == x);
	assert(((n[4] << 4) | n[8]) == z);
	assert(((n[5] << 4) | n[9]) == 0x00);
	if (count > 10) assert(n[10] == (BYTE)((ab << 2) | 0x03));
	if (count > 11) assert(n[11] == 0x0f);
}

int main(void)
{
	BYTE nib[12];

	Joystick_Init();
	Joystick_SetCPUClockMHz(10);

	/* Off: the ordinary digital joystick. */
	X68000_Joystick_Set(0, JOY_UP | JOY_TRG2);
	Joystick_Update();
	assert(!X68000_Joystick_IsCyberStick(0));
	assert(Joystick_Read(0) == (BYTE)~(JOY_UP | JOY_TRG2));

	/* On: idle lines are L/H low, ACK high, data all ones. */
	X68000_Joystick_SetCyberStick(0, 1);
	assert(X68000_Joystick_IsCyberStick(0));
	assert(!X68000_Joystick_IsCyberStick(1));
	assert(Joystick_Read(0) == 0xdf);

	/* Stick up, trigger A, throttle 0x3c, read the Sharp way at 10 MHz. */
	X68000_Joystick_SetThrottle(0, 0x3c);
	assert(X68000_Joystick_CyberStickRequests(0) == 0);
	read_sharp(nib);
	assert(X68000_Joystick_CyberStickRequests(0) == 1);
	check_report(nib, 12, 0x00, 0x80, 0x3c, 0x01);
	/* After the report the lines go idle again. */
	run(1000);
	assert(Joystick_Read(0) == 0xdf);

	/* Down-right, trigger B, full throttle forward, at 24 MHz. */
	Joystick_SetCPUClockMHz(24);
	X68000_Joystick_Set(0, JOY_DOWN | JOY_RIGHT | JOY_TRG1);
	X68000_Joystick_SetThrottle(0, 0x00);
	read_sharp(nib);
	check_report(nib, 12, 0xff, 0xff, 0x00, 0x02);

	/* A slow poller (still more than one read per 10 us half step). */
	poll_cycles = 200;
	X68000_Joystick_Set(0, JOY_LEFT);
	X68000_Joystick_SetThrottle(0, 0xc8);
	read_sharp(nib);
	check_report(nib, 12, 0x80, 0x00, 0xc8, 0x03);

	/* A new falling edge in the middle of a report starts over with fresh data. */
	poll_cycles = 40;
	req(1);
	req(0);
	run(24 * 120);                  /* a few nibbles into the report */
	X68000_Joystick_Set(0, JOY_UP);
	X68000_Joystick_SetThrottle(0, 0x80);
	read_sharp(nib);
	check_report(nib, 12, 0x00, 0x80, 0x80, 0x03);

	/* Switching it off returns to the digital joystick (pin 8 low selects the
	 * ordinary lines; px68k uses pin 8 high for a 6-button pad's extra ones). */
	X68000_Joystick_SetCyberStick(0, 0);
	req(0);
	Joystick_Update();
	assert(Joystick_Read(0) == (BYTE)~JOY_UP);

	printf("PASS: CYBER STICK reports (Sharp driver reads at 10 / 24 MHz, slow polling, restart), idle lines, digital fallback (%ld port reads)\n", reads);
	return 0;
}
