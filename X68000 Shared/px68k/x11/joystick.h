#ifndef winx68k_joy_h
#define winx68k_joy_h

#include "common.h"
#include <stdint.h>

#define	JOY_UP		0x01
#define	JOY_DOWN	0x02
#define	JOY_LEFT	0x04
#define	JOY_RIGHT	0x08
#define	JOY_TRG2	0x20
#define	JOY_TRG1	0x40

#define	JOY_TRG5	0x01
#define	JOY_TRG4	0x02
#define	JOY_TRG3	0x04
#define	JOY_TRG7	0x08
#define	JOY_TRG8	0x20
#define	JOY_TRG6	0x40

void Joystick_Init(void);
void Joystick_Cleanup(void);
BYTE FASTCALL Joystick_Read(BYTE num);
void FASTCALL Joystick_Write(BYTE num, BYTE data);
void FASTCALL Joystick_Update(void);

// CYBER STICK (Sharp CZ-8NJ2, Dempa XE-1AJ protocol) in analog mode on a joystick port.
// The stick and triggers A/B come from X68000_Joystick_Set; the throttle is set separately.
void X68000_Joystick_SetCyberStick(BYTE num, int enabled);
int X68000_Joystick_IsCyberStick(BYTE num);
// Throttle (channel 2): 0x00 = pushed fully forward ... 0xFF = pulled fully back, 0x80 = middle.
void X68000_Joystick_SetThrottle(BYTE num, BYTE value);

// Emulated CPU time for the CYBER STICK protocol: the main loop reports each executed
// slice and the clock; WinX68k_CyclesInSlice (winx68k.cpp) gives the progress inside
// the slice that is running.
void Joystick_CPUSliceDone(int cycles);
void Joystick_SetCPUClockMHz(long mhz);
int WinX68k_CyclesInSlice(void);

extern BYTE joy[2];
extern BYTE JoyKeyState;
extern BYTE JoyKeyState0;
extern BYTE JoyKeyState1;
extern BYTE JoyState0[2];
extern BYTE JoyState1[2];
extern BYTE JoyPortData[2];

#endif
