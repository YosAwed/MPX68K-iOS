// ciscタンノエロガゾウキボンヌを強引にけろぴーに繋ぐための
// extern "C" の入れ方がきちゃなくてステキ（ぉ

// readme.txtに従って、改変点：
//  - opna.cppにYMF288用のクラス追加してます。OPNAそのまんまだけどね（ほんとは正しくないがまあいいや）
//  - 多分他は弄ってないはず……

extern "C" {

#include "common.h"
#include "winx68k.h"
#include "dswin.h"
#include "prop.h"
#include "mfp.h"
#include "adpcm.h"
#include "fdc.h"
#include "fmg_wrap.h"

#include "opm.h"
};

class MyOPM : public FM::OPM
{
public:
	MyOPM();
	virtual ~MyOPM() {}
	void WriteIO(DWORD adr, BYTE data);
	void Count2(DWORD clock);
	void ResetMonitor();

	// Copy of the registers for the sound monitor panel (fmgen keeps no readable copy).
	BYTE MonitorRegs[256];
	// Slots keyed on per channel (bit 0 M1, 1 C1, 2 M2, 3 C2), from register $08.
	BYTE MonitorSlots[8];
	// Counts key-ons per channel, so a note shorter than one UI frame still shows.
	unsigned int MonitorKeyOns[8];
private:
	void MonitorWrite(int reg, BYTE data);
	virtual void Intr(bool);
	int CurReg;
	DWORD CurCount;
};


MyOPM::MyOPM()
{
	CurReg = 0;
	ResetMonitor();
}

void MyOPM::ResetMonitor()
{
	memset(MonitorRegs, 0, sizeof(MonitorRegs));
	memset(MonitorSlots, 0, sizeof(MonitorSlots));
	memset(MonitorKeyOns, 0, sizeof(MonitorKeyOns));
}

void MyOPM::MonitorWrite(int reg, BYTE data)
{
	MonitorRegs[reg&0xff] = data;
	if ( reg==0x08 ) {
		// Key on/off: the register only holds the last write, so keep each channel's slots.
		int ch = data&7;
		BYTE slots = (data>>3)&0x0f;
		if ( slots && !MonitorSlots[ch] ) MonitorKeyOns[ch]++;
		MonitorSlots[ch] = slots;
	}
}

#define FM_MIDI_OUT (0)

#if FM_MIDI_OUT
extern "C" void X68000_AddMIDIBuffer( const BYTE data );
static BYTE s_KeyCode[8];
static BYTE s_old_KeyCode[8];
static BYTE s_KF[8];


static const char KeyCodeTable[] = {
//    D#    E    F   F#    G   G#    A   A# B +1 C C# D....
    0x00,0x01,0x02,0x04,0x05,0x06,0x08,0x09,    // D#
    0x0a,0x0c,0x0d,0x0e,0x10,0x11,0x12,0x14,
    0x15,0x16,0x18,0x19,0x1a,0x1c,0x1d,0x1e,
    0x20,0x21,0x22,0x24,0x25,0x26,0x28,0x29,
    0x2a,0x2c,0x2d,0x2e,0x30,0x31,0x32,0x34,
    0x35,0x36,0x38,0x39,0x3a,0x3c,0x3d,0x3e,
    0x40,0x41,0x42,0x44,0x45,0x46,0x48,0x49,
    0x4a,0x4c,0x4d,0x4e,0x50,0x51,0x52,0x54,
    0x55,0x56,0x58,0x59,0x5a,0x5c,0x5d,0x5e,
    0x60,0x61,0x62,0x64,0x65,0x66,0x68,0x69,
    0x6a,0x6c,0x6d,0x6e,0x70,0x71,0x72,0x74,
    0x75,0x76,0x78,0x79,0x7a,0x7c,0x7d,0x7e,
};
#endif

void MyOPM::WriteIO(DWORD adr, BYTE data)
{
	if( adr&1 ) {
		if ( CurReg==0x1b ) {
			::ADPCM_SetClock((data>>5)&4);
			::FDC_SetForceReady((data>>6)&1);
		}
		SetReg((int)CurReg, (int)data);
		MonitorWrite(CurReg, data);
#if FM_MIDI_OUT
        if ( CurReg >= 0x08 ) {
            int ch = data & 0x07;
            int KeyOnOff = (data >> 3) & 0x0f;

            int send = s_KeyCode[ch];

            if ( KeyOnOff == 0 ) {

                X68000_AddMIDIBuffer( 0x80+ch );    // Note On
                X68000_AddMIDIBuffer( s_KeyCode[ch] );    // Key
                X68000_AddMIDIBuffer( 0 );     // Vel

            } else {
        }

        }

        if (( CurReg >= 0x28 ) && ( CurReg <= 0x2f )) {
            int ch = CurReg - 0x28;
            int d = data;
            int Note = d & 0x0f; // 4bit(0-15)
            int Oct = (d >> 4) & 0x07; // 3bit(0-7)
            int KC = (d>>7) & 0x01;
            if ( Note >= 12 ) {
                Note = Note % 12;
                Oct += 1;
            }
            int send = 0;
            for ( int i=0; i<sizeof(KeyCodeTable);++i ) {
                if ( KeyCodeTable[i] == d & 0x7f ) {
                    send = i + 3;
                    break;
                }
            }
            //            printf("%02x CH:%d KC:%d KF:%3d Oct:%d Note:%2d = %3d(%02x)\n", d, ch, KC, s_KF[ch], Oct, Note, send, send);

            X68000_AddMIDIBuffer( 0x80+ch );    // Note On
            X68000_AddMIDIBuffer( s_KeyCode[ch] );    // Key
            X68000_AddMIDIBuffer( 0 );     // Vel

            X68000_AddMIDIBuffer( 0x90+ch );    // Note On
            X68000_AddMIDIBuffer( send );    // Key
            X68000_AddMIDIBuffer( 127 );     // Vel

            s_old_KeyCode[ch] = s_KeyCode[ch];
            s_KeyCode[ch] = send;//12*Oct + Note;


            
        }
        if ( CurReg == 0x30 ) {
            int ch = CurReg - 0x30;
            s_KF[ch] = data>>2;
        }
#endif
        
    } else {
		CurReg = (int)data;
	}
}

void MyOPM::Intr(bool f)
{
	if ( f ) ::MFP_Int(12);
}


void MyOPM::Count2(DWORD clock)
{
	CurCount += clock;
	Count(CurCount/10);
	CurCount %= 10;
}


static MyOPM* opm = NULL;

int OPM_Init(int clock, int rate)
{
	opm = new MyOPM();
	if ( !opm ) return FALSE;
	if ( !opm->Init(clock, rate, TRUE) ) {
		delete opm;
		opm = NULL;
		return FALSE;
	}
	return TRUE;
}


void OPM_Cleanup(void)
{
    delete opm;
	opm = NULL;
}


void OPM_SetRate(int clock, int rate)
{
	if ( opm ) opm->SetRate(clock, rate, TRUE);
}


void OPM_Reset(void)
{
	if ( opm ) {
		opm->Reset();
		opm->ResetMonitor();
	}
}


BYTE FASTCALL OPM_Read(WORD adr)
{
	BYTE ret = 0;
	(void)adr;
	if ( opm ) ret = opm->ReadStatus();
    return ret;
}


void FASTCALL OPM_Write(DWORD adr, BYTE data)
{
    
    
	if ( opm ) opm->WriteIO(adr, data);
}


void OPM_Update(short *buffer, int length, int rate, BYTE *pbsp, BYTE *pbep)
{
    if ( opm ) opm->Mix((FM::Sample*)buffer, length, rate, pbsp, pbep);
}


void FASTCALL OPM_Timer(DWORD step)
{
	if ( opm ) opm->Count2(step);
}


void OPM_SetVolume(BYTE vol)
{
	int v = (vol)?((16-vol)*4):192;		// このくらいかなぁ
	if ( opm ) opm->SetVolume(-v);
}


// -----------------------------------------------------------------------
//   Sound monitor (read from the UI on the emulation thread)
// -----------------------------------------------------------------------
extern "C" void X68000_GetOPMMonitor(unsigned char *regs, unsigned char *slots, unsigned int *keyOns)
{
	if ( !opm ) {
		if ( regs ) memset(regs, 0, 256);
		if ( slots ) memset(slots, 0, 8);
		if ( keyOns ) memset(keyOns, 0, sizeof(unsigned int)*8);
		return;
	}
	if ( regs ) memcpy(regs, opm->MonitorRegs, 256);
	if ( slots ) memcpy(slots, opm->MonitorSlots, 8);
	if ( keyOns ) memcpy(keyOns, opm->MonitorKeyOns, sizeof(unsigned int)*8);
}

extern "C" int X68000_GetADPCMMonitor(int *pan, int *output, unsigned int *sampleRate)
{
	ADPCMMonitorState state;
	ADPCM_GetMonitorState(&state);
	if ( pan ) *pan = state.pan;
	if ( output ) *output = state.output;
	// ADPCM_Clocks are 12 times the sample rate (8 MHz / 512 -> 187500).
	if ( sampleRate ) *sampleRate = (unsigned int)(state.clockRate/12);
	return state.playing;
}
