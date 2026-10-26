| cyberstick.s -- X68000 self-booting CYBER STICK (analog mode) reader for
| MPX68K.
|
| Reads joystick 1 the way Sharp's driver does: a falling edge on REQ
| (PPI port C bit 4), then twelve nibbles, each pair as
|   wait L/H (port A bit 5) low, wait ACK (bit 6) low, read D0-D3,
|   wait L/H high, wait ACK low, read D0-D3,
| raising REQ again after eight nibbles. Interrupts are masked while the
| report is read. Shows the stick (Y, X), the throttle with a bar, the
| buttons, and how many reports were read or timed out.
|
| Runs from the floppy boot sector using only IPLROM IOCS services
| (_CRTMOD $10, _B_PRINT $21, _B_LOCATE $23, _OS_CUROF $AF) -- no Human68k,
| no copyrighted content on the disk. Position independent; must fit in the
| 1024-byte boot sector. Assemble with GNU binutils for m68k (see build.sh).

        .equ    PORTA, 0xe9a001
        .equ    PPICTL, 0xe9a007
        .equ    TIMEOUT, 0x3fff

        .text
        .global entry
entry:
        bra.s   start
        .ascii  "MPX68K CYBER"          | id string
        .even
start:
        moveq   #0x10,%d0               | _CRTMOD 16: 768x512, clears screen
        moveq   #16,%d1
        trap    #15
        move.l  #0xaf,%d0               | _OS_CUROF
        trap    #15
        moveq   #0,%d1
        moveq   #0,%d2
        lea     s_title(%pc),%a1
        bsr     printat
        moveq   #0,%d6                  | reports read
        moveq   #0,%d7                  | timeouts

mainloop:
        bsr     readstick
        lea     nib(%pc),%a0
        tst.l   %d0
        bne.s   1f
        addq.l  #1,%d6
        bra.s   2f
1:      addq.l  #1,%d7
2:
| ---- line 3: Y X THROTTLE ---------------------------------------------
        moveq   #0,%d1
        moveq   #3,%d2
        lea     s_y(%pc),%a1
        bsr     printat
        moveq   #2,%d4                  | Y = nibble 3 / 7
        bsr     printchan
        lea     s_x(%pc),%a1
        bsr     print
        moveq   #3,%d4                  | X = nibble 4 / 8
        bsr     printchan
        lea     s_z(%pc),%a1
        bsr     print
        moveq   #4,%d4                  | throttle = nibble 5 / 9
        bsr     printchan
| bar: one '#' per 16 steps forward (0x00 = fully forward)
        not.b   %d5
        lsr.b   #4,%d5
        moveq   #15,%d3
        lea     bar(%pc),%a1
3:      move.b  #'-',(%a1)
        tst.b   %d5
        beq.s   4f
        move.b  #'#',(%a1)
        subq.b  #1,%d5
4:      addq.l  #1,%a1
        dbra    %d3,3b
        move.b  #']',(%a1)+
        clr.b   (%a1)
        lea     s_bar(%pc),%a1
        bsr     print
| ---- line 5: nibbles, buttons -----------------------------------------
        moveq   #0,%d1
        moveq   #5,%d2
        lea     s_nib(%pc),%a1
        bsr     printat
        lea     nib(%pc),%a0
        moveq   #11,%d4
5:      move.b  (%a0)+,%d0
        ror.l   #4,%d0
        moveq   #0,%d3
        bsr     printhex
        dbra    %d4,5b
        lea     s_btn(%pc),%a1
        bsr     print
        lea     nib(%pc),%a0
        move.b  (%a0),%d0               | nibble 1: A B C D, active low
        ror.l   #4,%d0
        moveq   #0,%d3
        bsr     printhex
| ---- line 7: counters -------------------------------------------------
        moveq   #0,%d1
        moveq   #7,%d2
        lea     s_ok(%pc),%a1
        bsr     printat
        move.l  %d6,%d0
        bsr     printhex8
        lea     s_err(%pc),%a1
        bsr     print
        move.l  %d7,%d0
        bsr     printhex8
        bra     mainloop

| Reads one report into nib. d0 = 0 on success, -1 on a timeout.
readstick:
        move.w  %sr,-(%sp)
        ori.w   #0x0700,%sr
        lea     nib(%pc),%a0
        move.b  #0x09,PPICTL            | REQ high
        nop
        move.b  #0x08,PPICTL            | REQ low: falling edge starts a report
        moveq   #5,%d3                  | six pairs of nibbles
6:      moveq   #0,%d1                  | wait L/H low
        bsr.s   waitlh
        bsr.s   waitack
        moveq   #0x20,%d1               | wait L/H high
        bsr.s   waitlh
        bsr.s   waitack
        cmpi.w  #2,%d3                  | eight nibbles read: raise REQ
        bne.s   7f
        move.b  #0x09,PPICTL
7:      dbra    %d3,6b
        moveq   #0,%d0
rs_end: move.w  (%sp)+,%sr
        rts

| waitlh: wait until port A bit 5 == d1 (0 or $20)
waitlh: move.w  #TIMEOUT,%d2
8:      move.b  PORTA,%d0
        andi.b  #0x20,%d0
        cmp.b   %d1,%d0
        beq.s   9f
        dbra    %d2,8b
        bra.s   timeout
9:      rts

| waitack: wait until ACK (bit 6) is low, then store D0-D3
waitack:
        move.w  #TIMEOUT,%d2
10:     move.b  PORTA,%d0
        btst    #6,%d0
        beq.s   11f
        dbra    %d2,10b
        bra.s   timeout
11:     andi.b  #15,%d0
        move.b  %d0,(%a0)+
        rts

timeout:
        addq.l  #4,%sp                  | drop the wait's return address
        move.b  #0x09,PPICTL
        moveq   #-1,%d0
        bra.s   rs_end

| printchan: print channel d4 (high nibble at nib+d4, low at nib+d4+4) as
| two hex digits; leaves the value in d5.
printchan:
        lea     nib(%pc),%a0
        move.b  0(%a0,%d4.w),%d5
        lsl.b   #4,%d5
        or.b    4(%a0,%d4.w),%d5
        moveq   #0,%d0
        move.b  %d5,%d0
        ror.l   #8,%d0
        moveq   #1,%d3
        bra.s   printhex

| ---- helpers -----------------------------------------------------------
printat:                                | d1=x, d2=y, a1=string
        moveq   #0x23,%d0               | _B_LOCATE
        trap    #15
print:                                  | a1=string
        moveq   #0x21,%d0               | _B_PRINT
        trap    #15
        rts

printhex8:                              | d0.l
        moveq   #7,%d3
printhex:                               | top d3+1 nibbles of d0
        lea     hexbuf(%pc),%a1
12:     rol.l   #4,%d0
        move.b  %d0,%d1
        andi.b  #15,%d1
        addi.b  #'0',%d1
        cmpi.b  #'9',%d1
        bls.s   13f
        addq.b  #7,%d1
13:     move.b  %d1,(%a1)+
        dbra    %d3,12b
        clr.b   (%a1)
        lea     hexbuf(%pc),%a1
        bra.s   print

s_title: .ascii "MPX68K CYBER STICK TEST - joystick 1, analog mode\r\n"
         .asciz "Disk menu > Joystick > CYBER STICK. Throttle 00 = forward."
s_y:     .asciz "Y $"
s_x:     .asciz "  X $"
s_z:     .asciz "  THROTTLE $"
s_bar:   .ascii "  ["
bar:     .space 18
s_nib:   .asciz "Nibbles "
s_btn:   .asciz "  A B C D (0=on) $"
s_ok:    .asciz "Reports $"
s_err:   .asciz "  timeouts $"
        .even
nib:    .space  12
hexbuf: .space  10
