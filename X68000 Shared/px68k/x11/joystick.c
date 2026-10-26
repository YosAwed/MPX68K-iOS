// JOYSTICK.C - joystick support for WinX68k

#include "common.h"
#include "prop.h"
#include "joystick.h"
//#include "winui.h"
#include "keyboard.h"


BYTE joy[2];
BYTE JoyKeyState;
BYTE JoyKeyState0;
BYTE JoyKeyState1;
BYTE JoyState0[2];
BYTE JoyState1[2];


BYTE JoyPortData[2];

// ---------------------------------------------------------------------------
//  CYBER STICK in analog mode
// ---------------------------------------------------------------------------
// The protocol follows MAME's micomxe1a.cpp (Dempa XE-1A family, BSD-3-Clause,
// Vas Crabb). A falling edge on REQ (joystick pin 8, PPI port C bit 4 / 5) makes the
// stick latch its state and send twelve nibbles on D0-D3 (port bits 0-3) by itself;
// the host cannot pace it and polls two lines:
//   L/H (pin 6, port bit 5): which half of a byte is on D0-D3 (low for nibbles 1, 3, ...)
//   ACK (pin 7, port bit 6): low while the nibble is valid
// Nibbles (D3..D0, buttons active low):
//    1: A B C D        2: E1 E2 START SELECT
//    3: Y7-4   4: X7-4   5: throttle 7-4   6: channel 3 7-4
//    7: Y3-0   8: X3-0   9: throttle 3-0  10: channel 3 3-0
//   11: A B A' B'     12: 1111
// Timing as in MAME: the first nibble is ready 50 us after the edge, each half step
// (L/H change with ACK high, then data with ACK low) takes 10 us. Sharp's driver and
// the CSK-style algorithm used by some games both read this.

#define CYBER_START_US		50
#define CYBER_HALF_STEP_US	10
#define CYBER_NIBBLES		12

typedef struct {
	int enabled;
	BYTE throttle;
	BYTE nibble[CYBER_NIBBLES];
	int active;			// a report is being sent
	uint64_t start;		// CPU cycles at which the first nibble's half steps begin
} CyberStick;

static CyberStick cyber[2] = {
	{ 0, 0x80, { 0 }, 0, 0 },
	{ 0, 0x80, { 0 }, 0, 0 },
};
static uint64_t cpu_cycles = 0;		// cycles of the finished CPU slices
static long cpu_clock_mhz = 10;

void Joystick_CPUSliceDone(int cycles)
{
	if (cycles > 0) cpu_cycles += (uint64_t)cycles;
}

void Joystick_SetCPUClockMHz(long mhz)
{
	cpu_clock_mhz = (mhz < 1) ? 1 : mhz;
}

static uint64_t Joystick_Now(void)
{
	int done = WinX68k_CyclesInSlice();
	return cpu_cycles + (uint64_t)((done > 0) ? done : 0);
}

void X68000_Joystick_SetCyberStick(BYTE num, int enabled)
{
	if (num > 1) return;
	cyber[num].enabled = enabled ? 1 : 0;
	cyber[num].active = 0;
}

int X68000_Joystick_IsCyberStick(BYTE num)
{
	return (num <= 1) ? cyber[num].enabled : 0;
}

void X68000_Joystick_SetThrottle(BYTE num, BYTE value)
{
	if (num <= 1) cyber[num].throttle = value;
}

// Latches a report from the digital state (stick at full deflection, triggers A/B).
static void Cyber_Latch(BYTE num, BYTE digital)
{
	// digital: X68000 port bits, active low
	const BYTE y = !(digital & JOY_UP) ? 0x00 : !(digital & JOY_DOWN) ? 0xff : 0x80;
	const BYTE x = !(digital & JOY_LEFT) ? 0x00 : !(digital & JOY_RIGHT) ? 0xff : 0x80;
	const BYTE z = cyber[num].throttle;
	const BYTE ch3 = 0x00;
	const BYTE a = (digital & JOY_TRG2) ? 1 : 0;	// trigger A (pin 6), 1 = released
	const BYTE b = (digital & JOY_TRG1) ? 1 : 0;	// trigger B (pin 7)
	BYTE *n = cyber[num].nibble;

	n[0] = (BYTE)((a << 3) | (b << 2) | 0x03);	// A B C D
	n[1] = 0x0f;					// E1 E2 START SELECT
	n[2] = y >> 4;
	n[3] = x >> 4;
	n[4] = z >> 4;
	n[5] = ch3 >> 4;
	n[6] = y & 0x0f;
	n[7] = x & 0x0f;
	n[8] = z & 0x0f;
	n[9] = ch3 & 0x0f;
	n[10] = (BYTE)((a << 3) | (b << 2) | 0x03);	// A B A' B'
	n[11] = 0x0f;
}

static BYTE Cyber_Read(BYTE num)
{
	CyberStick *c = &cyber[num];
	BYTE data = 0x0f, lh = 0, ack = 1;

	if (c->active) {
		const uint64_t now = Joystick_Now();
		const uint64_t half = (uint64_t)CYBER_HALF_STEP_US * (uint64_t)cpu_clock_mhz;
		if (now >= c->start) {
			const uint64_t phase = (now - c->start) / half;
			const uint64_t step = phase >> 1;
			if (step >= CYBER_NIBBLES) {
				c->active = 0;		// idle: last nibble, L/H low, ACK high
				data = c->nibble[CYBER_NIBBLES - 1];
			} else {
				lh = (BYTE)(step & 1);
				if (phase & 1) {
					data = c->nibble[step];
					ack = 0;
				} else {
					// L/H has changed; the previous nibble is still on the lines
					data = step ? c->nibble[step - 1] : 0x0f;
				}
			}
		}
	}
	return (BYTE)(0x90 | (ack << 6) | (lh << 5) | (data & 0x0f));
}



void Joystick_Init(void)
{

	joy[0] = 1;  // active only one
	joy[1] = 0;
	JoyKeyState = 0;
	JoyKeyState0 = 0;
	JoyKeyState1 = 0;
	JoyState0[0] = 0xff;
	JoyState0[1] = 0xff;
	JoyState1[0] = 0xff;
	JoyState1[1] = 0xff;
	JoyPortData[0] = 0;
	JoyPortData[1] = 0;


}

void Joystick_Cleanup(void)
{
}

BYTE FASTCALL Joystick_Read(BYTE num)
{
	BYTE joynum = num;
	BYTE ret0 = 0xff, ret1 = 0xff, ret;

	if (num <= 1 && cyber[num].enabled) {
		return Cyber_Read(num);
	}

	if (joy[num]) {
		ret0 = JoyState0[num];
		ret1 = JoyState1[num];
	}

	ret = ((~JoyPortData[num])&ret0)|(JoyPortData[num]&ret1);

	return ret;
}


static BYTE s_JoyData[2] = { 0xff, 0xff };

void FASTCALL Joystick_Write(BYTE num, BYTE data)
{
//    printf("Joystick %d:%02x\n", num, data);
	if ( (num==0)||(num==1) ) {
		// CYBER STICK: a falling edge on REQ (pin 8) starts a report
		if (cyber[num].enabled && JoyPortData[num] && !data) {
			Cyber_Latch(num, s_JoyData[num]);
			cyber[num].start = Joystick_Now()
				+ (uint64_t)CYBER_START_US * (uint64_t)cpu_clock_mhz;
			cyber[num].active = 1;
		}
		JoyPortData[num] = data;
	}
}

void X68000_Joystick_Set(BYTE num, BYTE data)
{
    if ( (num==0)||(num==1) ) s_JoyData[num] = ~data;   // Neg. Logic
}

void FASTCALL Joystick_Update(void)
{
    for ( int i=0; i<2; ++i ) {
        JoyState0[i] = s_JoyData[i];
        JoyState1[i] = 0xff;    // for MD Pad 6B
    }
}
