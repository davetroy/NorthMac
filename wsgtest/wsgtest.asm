; wsgtest.asm — standalone NS-WSG demo for the NorthStar Advantage.
;
; Probes the six I/O slots for the NS-WSG card (board ID 0xA5, STATUS 0x57),
; uploads three waveforms, then plays forever:
;   voice 0: arpeggio melody on a triangle wave
;   voice 1: low drone on a pseudo-sine
;   voice 2: slow siren sweep on the pseudo-sine
;
; Video: draws one wide bar per detected state so the machine shows life —
;   bar at scanline 40: program running
;   bar at scanline 60: WSG found (absent = card not detected; sound skipped)
;
; Build: z80asm -o wsgtest.bin wsgtest.asm
; Boot disk: python3 ../pacman/mkdisk.py ../pacman/stage1.bin wsgtest.bin wsgtest.nsi
; Headless: cc -O2 -I<z80 dir> run_wsg.c -o run_wsg && ./run_wsg wsgtest.bin out.wav

IOCTL:   equ 0f8h

; NS-WSG register offsets (base discovered by slot probe)
RWTIDX:  equ 0
RWTDAT:  equ 1
RCTRL:   equ 2
RSTAT:   equ 3

wbase:   equ 0c900h             ; discovered card base port
sirf:    equ 0c902h             ; siren frequency (16-bit)
sird:    equ 0c904h             ; siren direction (+/- step)

        org 8000h

        di
        ld   sp,0fe00h
        ld   a,0f8h             ; logical 0x0000 -> video page 8
        out  (0a0h),a
        ld   a,0f9h
        out  (0a1h),a
        xor  a
        out  (090h),a           ; scanline scroll 0
        out  (0b0h),a
        ld   a,18h              ; IOCTL baseline: bit 4 SET, always
        out  (IOCTL),a

        call cls
        ld   e,40               ; bar 1: alive
        call bar

        ; ---- probe slots for the NS-WSG (ID 0xA5 at ports 0x70-0x75) ----
        ld   c,70h
        ld   b,6                ; ID index 0..5 -> slot 6..1
probe:
        in   a,(c)
        cp   0a5h
        jr   z,found
        inc  c
        djnz probe
        jp   idle               ; no card: bars only

found:
        ; base port = idx * 16 (ID index 0=slot6@0x00 .. 5=slot1@0x50)
        ld   a,c
        sub  70h                ; a = ID index
        add  a,a
        add  a,a
        add  a,a
        add  a,a                ; * 16
        ld   (wbase),a
        ; confirm STATUS byte
        add  a,RSTAT
        ld   c,a
        in   a,(c)
        cp   057h
        jp   nz,idle

        ld   e,60               ; bar 2: WSG detected
        call bar

        ; ---- upload waveforms 0-2 (96 nibbles from wavedat) ----
        ld   a,(wbase)
        ld   c,a                ; C = WTIDX port
        xor  a
        out  (c),a              ; index 0
        inc  c                  ; C = WTDAT port
        ld   hl,wavedat
        ld   b,96
wup:
        ld   a,(hl)
        inc  hl
        out  (c),a
        djnz wup

        ; ---- enable, set the static voices ----
        ld   a,(wbase)
        add  a,RCTRL
        ld   c,a
        ld   a,1
        out  (c),a              ; master enable

        ; voice 1 drone: C3 (freq 1429 = 0x0595), wave 0, volume 6
        ld   a,(wbase)
        add  a,8                ; voice 1 FLO
        ld   c,a
        ld   a,095h
        out  (c),a
        inc  c
        ld   a,005h
        out  (c),a
        inc  c
        xor  a
        out  (c),a
        inc  c
        ld   a,006h             ; vol 6, wave 0
        out  (c),a

        ; voice 2 siren: start 1000, wave 0, volume 5
        ld   hl,1000
        ld   (sirf),hl
        ld   hl,8
        ld   (sird),hl
        ld   a,(wbase)
        add  a,0fh              ; voice 2 VW
        ld   c,a
        ld   a,005h             ; vol 5, wave 0
        out  (c),a

        ; voice 0 melody setup: wave 1, volume 12
        ld   a,(wbase)
        add  a,7                ; voice 0 VW
        ld   c,a
        ld   a,01ch             ; vol 12, wave 1
        out  (c),a

; ---- demo loop: melody notes, siren swept between them --------------------
demo:
        ld   ix,melody
note:
        ld   a,(ix+0)
        or   (ix+1)
        jr   nz,n1
        ld   ix,melody          ; wrap
        jr   note
n1:
        ld   a,(wbase)
        add  a,4                ; voice 0 FLO
        ld   c,a
        ld   a,(ix+0)
        out  (c),a
        inc  c
        ld   a,(ix+1)
        out  (c),a
        inc  c
        xor  a
        out  (c),a
        inc  ix
        inc  ix

        ld   b,60               ; ~0.18 s per note, sweeping the siren
d1:
        push bc
        call sirstep
        ld   bc,1100
d2:
        dec  bc
        ld   a,b
        or   c
        jr   nz,d2
        pop  bc
        djnz d1
        jr   note

; sirstep — advance the siren by one step and reload voice 2 frequency
sirstep:
        ld   hl,(sirf)
        ld   de,(sird)
        add  hl,de
        ld   (sirf),hl
        ld   de,3000
        or   a
        sbc  hl,de
        add  hl,de
        jr   c,ss1
        ld   hl,-8              ; hit the top: sweep down
        ld   (sird),hl
        jr   ss2
ss1:
        ld   de,1000
        or   a
        sbc  hl,de
        add  hl,de
        jr   nc,ss2
        ld   hl,8               ; hit the bottom: sweep up
        ld   (sird),hl
ss2:
        ld   a,(wbase)
        add  a,0ch              ; voice 2 FLO
        ld   c,a
        ld   hl,(sirf)
        ld   a,l
        out  (c),a
        inc  c
        ld   a,h
        out  (c),a
        inc  c
        xor  a
        out  (c),a
        ret

idle:
        jr   idle

; cls — zero the whole frame buffer (80 columns x 256 scanlines)
cls:
        ld   h,0
cl1:
        ld   l,0
cl2:
        ld   (hl),0
        inc  l
        jr   nz,cl2
        inc  h
        ld   a,h
        cp   80
        jr   nz,cl1
        ret

; bar — draw a solid bar 8 scanlines tall at scanline E, columns 10-69
bar:
        ld   b,10
br1:
        ld   h,b
        ld   l,e
        ld   c,8
br2:
        ld   (hl),0ffh
        inc  l
        dec  c
        jr   nz,br2
        inc  b
        ld   a,b
        cp   70
        jr   nz,br1
        ret

; ---- data -----------------------------------------------------------------
; three 32-nibble waveforms: 0 = pseudo-sine, 1 = triangle, 2 = 25% pulse
wavedat:
        db  8,9,11,12,13,14,14,15,15,15,14,14,13,12,11,9
        db  8,6,4,3,2,1,1,0,0,0,1,1,2,3,4,6
        db  0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        db  15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0
        db  15,15,15,15,15,15,15,15,0,0,0,0,0,0,0,0
        db  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

; melody: C4 E4 G4 C5 G4 E4 (freq = Hz / 0.0915527)
melody:
        dw   2858, 3601, 4282, 5715, 4282, 3601
        dw   0
