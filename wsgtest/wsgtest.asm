; wsgtest.asm — standalone NS-WSG demo for the NorthStar Advantage.
;
; Probes the six I/O slots for the NS-WSG card (board ID 0xA5, STATUS 0x57),
; uploads four waveforms, then loops a reel of Pac-Man-style effects
; (all original renditions in the arcade spirit): waka chomps, power-pill
; gulp loop, ghost-eat zips, fruit chime, death warble with final bloops,
; a two-voice jingle, and the chase siren.
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

        ; ---- upload waveforms 0-3 (128 nibbles from wavedat) ----
        ld   a,(wbase)
        ld   c,a                ; C = WTIDX port
        xor  a
        out  (c),a              ; index 0
        inc  c                  ; C = WTDAT port
        ld   hl,wavedat
        ld   b,128
wup:
        ld   a,(hl)
        inc  hl
        out  (c),a
        djnz wup

        ; ---- enable ----
        ld   a,(wbase)
        add  a,RCTRL
        ld   c,a
        ld   a,1
        out  (c),a              ; master enable

; ---- effects reel ---------------------------------------------------------
show:
        call fx_waka
        call rest
        call fx_pill
        call rest
        call fx_eatg
        call rest
        call fx_fruit
        call rest
        call fx_death
        call rest
        call fx_jingle
        call rest
        call fx_siren
        call rest
        call rest
        jp   show

; ---------------------------------------------------------------------------
; helpers.  wout: write A to WSG reg E (preserves A,E; clobbers C)
; setf: load voice frequency — HL=freq, E=voice FLO offset (preserves HL,DE,E)
; dlyms: delay B milliseconds.  mute: all voices volume 0.
; ---------------------------------------------------------------------------
wout:
        push af
        ld   a,(wbase)
        add  a,e
        ld   c,a
        pop  af
        out  (c),a
        ret

setf:
        ld   a,l
        call wout
        inc  e
        ld   a,h
        call wout
        inc  e
        xor  a
        call wout
        dec  e
        dec  e
        ret

dlyms:
dm1:
        push bc
        ld   bc,150
dm2:
        dec  bc
        ld   a,b
        or   c
        jr   nz,dm2
        pop  bc
        djnz dm1
        ret

mute:
        xor  a
        ld   e,7
        call wout
        ld   e,0bh
        call wout
        ld   e,0fh
        call wout
        ret

rest:
        call mute
        ld   b,200
        call dlyms
        ld   b,200
        call dlyms
        ret

; ---------------------------------------------------------------------------
; waka — eight chomps, alternating quick down / up glisses on the saw wave
; ---------------------------------------------------------------------------
fx_waka:
        ld   b,8
fw1:
        push bc
        ld   a,3ch              ; vol 12, wave 3 (saw)
        ld   e,7
        call wout
        ld   a,b
        and  1
        jr   z,fw_up
        ld   hl,3500            ; "wa": gliss down
        ld   de,-230
        jr   fw_go
fw_up:
        ld   hl,1200            ; "ka": gliss up
        ld   de,230
fw_go:
        ld   c,10
fw2:
        push bc
        push de
        push hl
        ld   e,4
        call setf
        ld   b,6
        call dlyms
        pop  hl
        pop  de
        add  hl,de
        pop  bc
        dec  c
        jr   nz,fw2
        ld   a,30h              ; gap: volume 0
        ld   e,7
        call wout
        ld   b,45
        call dlyms
        pop  bc
        djnz fw1
        jp   mute

; ---------------------------------------------------------------------------
; power pill — a rising gulp loop, four times round
; ---------------------------------------------------------------------------
fx_pill:
        ld   a,1ah              ; vol 10, wave 1 (triangle)
        ld   e,7
        call wout
        ld   c,4
fp1:
        push bc
        ld   hl,800
        ld   b,8
fp2:
        push bc
        push hl
        ld   e,4
        call setf
        ld   b,12
        call dlyms
        pop  hl
        ld   de,200
        add  hl,de
        pop  bc
        djnz fp2
        pop  bc
        dec  c
        jr   nz,fp1
        jp   mute

; ---------------------------------------------------------------------------
; ghost eaten — four fast ascending zips, each starting higher (200/400/800/1600)
; ---------------------------------------------------------------------------
fx_eatg:
        ld   hl,500
        ld   c,4
fe1:
        push bc
        push hl
        ld   a,3dh              ; vol 13, wave 3
        ld   e,7
        call wout
        ld   b,24
fe2:
        push bc
        push hl
        ld   e,4
        call setf
        ld   b,4
        call dlyms
        pop  hl
        ld   de,230
        add  hl,de
        pop  bc
        djnz fe2
        ld   a,30h              ; gap
        ld   e,7
        call wout
        ld   b,90
        call dlyms
        pop  hl
        ld   de,350
        add  hl,de
        pop  bc
        dec  c
        jr   nz,fe1
        jp   mute

; ---------------------------------------------------------------------------
; fruit chime — quick two-note ding on the sine
; ---------------------------------------------------------------------------
fx_fruit:
        ld   a,0bh              ; vol 11, wave 0 (sine)
        ld   e,7
        call wout
        ld   hl,8563            ; G5
        ld   e,4
        call setf
        ld   b,70
        call dlyms
        ld   hl,11430           ; C6
        call setf
        ld   b,150
        call dlyms
        jp   mute

; ---------------------------------------------------------------------------
; death — long descending warble (wobbling pitch), then two low bloops
; ---------------------------------------------------------------------------
fx_death:
        ld   a,1ch              ; vol 12, wave 1
        ld   e,7
        call wout
        ld   hl,4200
        ld   c,36
fd1:
        push bc
        push hl
        ld   e,4
        call setf
        ld   b,7
        call dlyms
        pop  hl
        push hl
        ld   de,350             ; wobble up
        add  hl,de
        ld   e,4
        call setf
        ld   b,7
        call dlyms
        pop  hl
        ld   de,-100            ; and settle lower
        add  hl,de
        pop  bc
        dec  c
        jr   nz,fd1
        xor  a                  ; beat of silence
        ld   e,7
        call wout
        ld   b,80
        call dlyms
        ld   a,0ch              ; bloop, bloop
        ld   e,7
        call wout
        ld   hl,1000
        ld   e,4
        call setf
        ld   b,80
        call dlyms
        xor  a
        ld   e,7
        call wout
        ld   b,60
        call dlyms
        ld   a,0ch
        ld   e,7
        call wout
        ld   hl,800
        ld   e,4
        call setf
        ld   b,110
        call dlyms
        jp   mute

; ---------------------------------------------------------------------------
; jingle — short two-voice fanfare: melody on triangle, bass on sine
; ---------------------------------------------------------------------------
fx_jingle:
        ld   a,1ch              ; melody: vol 12, wave 1
        ld   e,7
        call wout
        ld   a,08h              ; bass: vol 8, wave 0
        ld   e,0bh
        call wout
        ld   ix,jingled
fj1:
        ld   l,(ix+0)
        ld   h,(ix+1)
        ld   a,l
        or   h
        jp   z,mute
        ld   e,4
        call setf
        ld   l,(ix+2)
        ld   h,(ix+3)
        ld   e,8
        call setf
        inc  ix
        inc  ix
        inc  ix
        inc  ix
        ld   b,110
        call dlyms
        jr   fj1

; ---------------------------------------------------------------------------
; siren — two full up-down sweeps
; ---------------------------------------------------------------------------
fx_siren:
        ld   a,09h              ; vol 9, wave 0
        ld   e,7
        call wout
        ld   c,2
fs1:
        ld   hl,1000            ; C survives the sweep: fs2/fs4 guard it
        ld   de,25
fs2:
        push bc
        push de
        push hl
        ld   e,4
        call setf
        ld   b,6
        call dlyms
        pop  hl
        pop  de
        add  hl,de
        ld   a,h
        cp   12                 ; past ~3000: turn around
        jr   c,fs3
        ld   de,-25
fs3:
        bit  7,d
        jr   z,fs4
        push de
        ld   de,1000
        or   a
        sbc  hl,de
        add  hl,de
        pop  de
        jr   nc,fs4
        pop  bc
        dec  c
        jr   nz,fs1x
        jp   mute
fs1x:
        jr   fs1
fs4:
        pop  bc
        jr   fs2

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
; four 32-nibble waveforms: 0 sine, 1 triangle, 2 = 25% pulse, 3 double saw
wavedat:
        db  8,9,11,12,13,14,14,15,15,15,14,14,13,12,11,9
        db  8,6,4,3,2,1,1,0,0,0,1,1,2,3,4,6
        db  0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        db  15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0
        db  15,15,15,15,15,15,15,15,0,0,0,0,0,0,0,0
        db  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db  0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
        db  0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15

; jingle: (melody, bass) pairs, 110 ms per step, 0 = end
; melody C5 E5 G5 C6 G5 E5 C5, bass alternating C3/G3
jingled:
        dw   5715, 1429
        dw   7199, 2141
        dw   8563, 1429
        dw  11430, 2141
        dw   8563, 1429
        dw   7199, 2141
        dw   5715, 1429
        dw   0, 0
