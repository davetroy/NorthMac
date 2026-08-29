; ============================================================================
; GREENFIELD — a purpose-built generative-art OS for the NorthStar Advantage
; ============================================================================
; No CP/M. No DOS. No legacy. Just the bare metal: the Z80, the framebuffer,
; and a hard-sectored floppy the stock boot PROM hands control to.
;
; THE PIECE: a flow-field particle tracer — the signature form of modern
; generative / plotter art — running on a 1982 machine. Hundreds of particles
; are released into a vector field woven from a sine table; each drifts along
; the field, leaving a trail, and the accumulated trails compose flowing
; filament structures. A 16-bit LFSR seeded from the Z80 refresh register
; randomises the field phase and every particle's birthplace, so the machine
; paints a different one-of-a-kind canvas on every cold boot.
;
; Boot contract (stock Advantage 2K PROM, reverse-engineered + verified against
; shipping system disks): the PROM reads track-0 sectors 4..7 (file 0x800..FFF,
; 2 KB) to load_page:0000, requires byte 0x00 == load page and byte 0x0A ==
; 0xC3 (a JP), then jumps to load_page:000A. The emulator runs this same PROM,
; so a disk that boots here boots on real iron written via Greaseweazle.
; ----------------------------------------------------------------------------

; ---- NorthStar Advantage I/O ports (high-nibble decoded) -------------------
SCANREG:  equ 090h        ; OUT: top-of-screen scanline (hardware vert. scroll)
MAP0:     equ 0a0h        ; OUT: map register, logical page 0 (0000-3FFF)
MAP1:     equ 0a1h        ; OUT: logical page 1 (4000-7FFF)
MAP2:     equ 0a2h        ; OUT: logical page 2 (8000-BFFF)
CLRDISP:  equ 0b0h        ; OUT: clear the display (vblank) flag
IOCTL:    equ 0f8h        ; OUT: I/O control (cmd, acquire, blank, spkr, int-en)

VRAM_LO:  equ 0f8h        ; map value: physical page 8 (video, columns 0..63)
VRAM_HI:  equ 0f9h        ; map value: physical page 9 (video, columns 64..79)
RAM1:     equ 001h        ; map value: physical RAM page 1 (scratch)
DISP_ON:  equ 010h        ; IOCTL: blank bit clear -> picture visible (bit4 held: real hardware freezes I/O without it)

NCOLS:    equ 80
STACKTOP: equ 0fe00h

; ---- run parameters --------------------------------------------------------
STEPS:    equ 200         ; flow mode: trail length (steps per particle)
NMODES:   equ 13          ; number of generative modes in the gallery rotation
NCELLS:   equ 640         ; CA mode: cells across one generation

; ---- zero-page-style variables in bank-3 RAM, above the 2 KB load image ----
prng:     equ 0ce00h      ; LFSR state (lo)
prngh:    equ 0ce01h      ; LFSR state (hi)
posx:     equ 0ce02h      ; particle x position, 16-bit fixed point (lo)
posxh:    equ 0ce03h
posy:     equ 0ce04h      ; particle y position (lo)
posyh:    equ 0ce05h
drift:    equ 0ce06h      ; per-run field phase offset
pcount:   equ 0ce07h      ; particles remaining
scount:   equ 0ce08h      ; steps remaining for current particle
tmpa:     equ 0ce09h      ; scratch (angle, then plot y)
tmpxi:    equ 0ce0ah      ; field x index
tmpyi:    equ 0ce0bh      ; field y index
tmpsx:    equ 0ce0ch      ; sin(xi)/2 warp term
mode:     equ 0ce0dh      ; current gallery mode
; harmonograph (mode_liss): 16-bit phase accumulators + fractional freqs.
; The fractional part makes frequency ratios irrational, so the curve never
; exactly closes — it precesses and fills, the classic harmonograph look.
px1:      equ 0ce0eh      ; (2)
px2:      equ 0ce10h      ; (2)
py1:      equ 0ce12h      ; (2)
py2:      equ 0ce14h      ; (2)
fx1:      equ 0ce16h      ; (2)
fx2:      equ 0ce18h      ; (2)
fy1:      equ 0ce1ah      ; (2)
fy2:      equ 0ce1ch      ; (2)
lcnt:     equ 0ce1eh      ; harmonograph point counter (16-bit)
; scrolling cellular automaton (mode_ca)
carule:   equ 0ce20h      ; elementary CA rule (0..255)
caw:      equ 0ce21h      ; current scanline (also generation #, wraps 0..255)
cacur:    equ 0ce22h      ; pointer to current generation buffer (2)
canxt:    equ 0ce24h      ; pointer to next generation buffer (2)
cagen:    equ 0ce26h      ; generations remaining (2)
cmd:      equ 0ce28h      ; control command from keyboard (0=none,1=skip,2=select)
txty:     equ 0ce29h      ; text top scanline (for the font renderer)
cseed:    equ 0ce2ah      ; LFSR snapshot identifying this canvas (2) -> signature
paceLvl:  equ 0ce2ch      ; software speed brake (0=flat out; higher=slower)
pha:      equ 0ce2dh      ; phyllotaxis angle / general mode scratch
phr:      equ 0ce2eh      ; phyllotaxis radius
phrs:     equ 0ce2fh      ; phyllotaxis radius-step countdown (integer sqrt)
mq:       equ 0ce30h      ; attractor/Mandelbrot fixed-point scratch (8 bytes)
; plasma scratch
pfx:      equ 0ce38h
pfy:      equ 0ce39h
psy:      equ 0ce3ah
pscan:    equ 0ce3bh
pix:      equ 0ce3ch
pidg:     equ 0ce3dh
pcol:     equ 0ce3eh
pacc:     equ 0ce3fh
pbit:     equ 0ce40h
; CA double-buffer in bank-3 RAM, above the load image. One byte per cell, with
; a zero guard byte on each side so the rule can read cell[-1] / cell[NCELLS].
GUARD_A0: equ 0d000h
CELLS_A:  equ 0d001h
GUARD_A1: equ 0d281h      ; 0xD001 + 640
GUARD_B0: equ 0d300h
CELLS_B:  equ 0d301h
GUARD_B1: equ 0d581h
; Game of Life: 80x48 cell grid with a 1-cell dead border (stride 82).
LIFEW:    equ 80
LIFEH:    equ 48
LSTR:     equ 82
LIFEA:    equ 0d000h       ; current generation (82*50 bytes)
LIFEB:    equ 0e200h       ; next generation
lcur:     equ 0ce41h       ; pointer to current buffer (2)
lnxt:     equ 0ce43h       ; pointer to next buffer (2)
lgen:     equ 0ce45h       ; generations remaining

; ============================================================================
; ============================================================================
; STAGE 2 — the art. Loaded by stage1 (the loader) into page 2 (bank 1) at
; 0x8000 and entered here. The framebuffer is mapped into pages 0/1; this code
; lives in page 2; variables, buffers and stack live in page-3 RAM (bank 3).
; Built as a flat binary at org 0x8000 (no PROM boot header — stage1 owns that).
; ============================================================================
        org 8000h
start:
        di
        ld   sp,STACKTOP

        ; framebuffer: video bank 8 at 0x0000, bank 9 at 0x4000. Page 2 (this
        ; code) and page 3 (data/stack) are left exactly as the loader set them.
        ld   a,VRAM_LO
        out  (MAP0),a
        ld   a,VRAM_HI
        out  (MAP1),a

        ; picture on, no scroll
        xor  a
        out  (SCANREG),a
        out  (CLRDISP),a
        ld   a,DISP_ON
        out  (IOCTL),a

        ; --- seed the LFSR from the refresh register (entropy at boot) ------
        ld   a,r
        ld   (prng),a
        ld   a,r
        cpl
        ld   (prngh),a
        ld   hl,(prng)                  ; LFSR must not be zero
        ld   a,h
        or   l
        jr   nz,seeded
        ld   hl,0ace1h
        ld   (prng),hl
seeded:
        xor  a
        ld   (mode),a
        ld   (cmd),a
        ld   (paceLvl),a                ; no brake: a real 4MHz Z80 is the pace.
                                        ; (- key adds brake for emulator turbo)

        ; === living gallery: rotate through generative modes forever =======
        ; Keys (polled while painting and while holding):
        ;   SPACE = new canvas (same mode) · 1/2/3 = pick mode · P = pause
        ;   + / - = faster / slower (software speed brake; run emulator in turbo)
gallery:
        call cls                        ; fresh black canvas
        ld   hl,(prng)                  ; snapshot the seed that defines this piece
        ld   (cseed),hl
        call rnd16                      ; per-canvas entropy (field phase, etc.)
        ld   (drift),a
        call chime                      ; ...and let the new canvas sing

        ld   a,(mode)                   ; dispatch to the current mode
        add  a,a                        ; *2 (table of 16-bit addresses)
        ld   e,a
        ld   d,0
        ld   hl,modetab
        add  hl,de
        ld   a,(hl)
        inc  hl
        ld   h,(hl)
        ld   l,a                        ; HL = mode routine
        call calhl                      ; paint one canvas (may abort via cmd)

        ld   a,(cmd)
        or   a
        jr   nz,gact                    ; aborted mid-paint -> act now, no hold
        call sign                       ; sign the finished piece
        call hold                       ; natural end -> linger
        ld   a,(cmd)
        or   a
        jr   nz,gact                    ; key during hold -> act
        ld   a,(mode)                   ; natural: rotate to next mode
        inc  a
        cp   NMODES
        jr   c,gset
        xor  a
gset:
        ld   (mode),a
gact:
        xor  a
        ld   (cmd),a                    ; consume the command
        jr   gallery

calhl:  jp   (hl)                       ; tail-call the routine in HL

modetab:
        dw   mode_flow
        dw   mode_liss
        dw   mode_ca
        dw   mode_chaos
        dw   mode_phyllo
        dw   mode_rose
        dw   mode_truchet
        dw   mode_walk
        dw   mode_mult
        dw   mode_plasma
        dw   mode_ripple
        dw   mode_mandel
        dw   mode_life

; ============================================================================
; mode_flow — domain-warped flow-field particle tracer (256 trails)
; ============================================================================
mode_flow:
        xor  a
        ld   (pcount),a                 ; 0 -> 256 iterations
floop:
        call ctlpoll                    ; stay responsive to keys mid-paint
        or   a
        ret  nz
        call pacedly                    ; software speed brake
        call rnd16                      ; random birthplace
        ld   (posxh),a
        call rnd16
        ld   (posx),a
        call rnd16
        ld   (posyh),a
        call rnd16
        ld   (posy),a

        ld   a,STEPS
        ld   (scount),a
fstep:
        call step                       ; advance + plot one step of the trail
        ld   a,(scount)
        dec  a
        ld   (scount),a
        jr   nz,fstep

        ld   a,(pcount)
        dec  a
        ld   (pcount),a
        jr   nz,floop
        ret

; ============================================================================
; mode_liss — harmonograph: x and y are each the sum of two sine phase
; accumulators at random frequencies, tracing delicate Lissajous loops that
; precess and weave. No multiply: phases advance by addition.
;   x = 256 + sin(px1) + sin(px2)          (px1+=fx1, px2+=fx2 each step)
;   y = 120 + sin(py1)/2 + sin(py2)/2
; ============================================================================
mode_liss:
        call lfreq                      ; fx = a*64   (a in 2..5)
        ld   (fx1),de
        call lfreq                      ; fy = b*64   -> ratio a:b sets the figure
        ld   (fy1),de
        ld   hl,0
        ld   (px1),hl
        call rnd16                      ; random y phase offset (varies the figure)
        ld   h,a
        ld   l,0
        ld   (py1),hl

        ld   hl,0c000h                  ; ~49k points (closed curve, traced sharp)
        ld   (lcnt),hl
lstep:
        ; x = 320 + 2*sin(px1>>8) ; px1 += fx1 ----------------------------
        ld   hl,(px1)
        ld   de,(fx1)
        add  hl,de
        ld   (px1),hl
        ld   a,h
        call sinlk
        ld   e,a
        add  a,a
        sbc  a,a
        ld   d,a                        ; DE = signext(sin)
        ld   hl,320                     ; centre (256 + 64 margin)
        add  hl,de
        add  hl,de                      ; + 2*sin -> screen_x (84..556)
        push hl
        ; y = 120 + sin(py1>>8) ; py1 += fy1 ------------------------------
        ld   hl,(py1)
        ld   de,(fy1)
        add  hl,de
        ld   (py1),hl
        ld   a,h
        call sinlk
        add  a,120                      ; y = 2..238
        ld   c,a
        pop  hl                         ; screen_x
        ld   a,c                        ; y
        call plot

        ld   hl,(lcnt)
        dec  hl
        ld   (lcnt),hl
        ld   a,l
        or   a
        jr   nz,lns                     ; once every 256 points: poll + pace
        call ctlpoll
        or   a
        ret  nz
        call pacedly                    ; software speed brake
lns:
        ld   a,h
        or   l
        jr   nz,lstep
        ret

; lfreq -> DE = m*64, m in 2..5. A slow angular frequency; the ratio between
; the x and y values sets the Lissajous figure, and the small integer m keeps
; the curve closed and continuous (sine index advances ~0.5..1.25 per step).
lfreq:
        call rnd16
        and  03h
        add  a,2                        ; m = 2..5
        ld   h,0
        ld   l,a
        add  hl,hl
        add  hl,hl
        add  hl,hl
        add  hl,hl
        add  hl,hl
        add  hl,hl                      ; HL = m*64
        ex   de,hl
        ret

; ============================================================================
; mode_ca — scrolling elementary cellular automaton (Wolfram space-time).
; A new generation is computed each step, packed into the next scanline, and
; the hardware scanline register (port 0x90) is advanced so the freshest line
; sits at the bottom and the whole history flows upward — using the real CRT
; scroll, not a memory copy. Random rule + random seed per canvas.
; ============================================================================
caRules:
        db   30, 90, 110, 150, 54, 62, 105, 73
mode_ca:
        call rnd16                      ; pick one of 8 interesting rules
        and  07h
        ld   e,a
        ld   d,0
        ld   hl,caRules
        add  hl,de
        ld   a,(hl)
        ld   (carule),a

        ld   de,CELLS_A                 ; seed generation 0 with random bits
        ld   bc,NCELLS
caseed:
        call rnd16                      ; (trashes HL/A only — DE,BC safe)
        and  1
        ld   (de),a
        inc  de
        dec  bc
        ld   a,b
        or   c
        jr   nz,caseed

        xor  a                          ; zero the four guard cells
        ld   (GUARD_A0),a
        ld   (GUARD_A1),a
        ld   (GUARD_B0),a
        ld   (GUARD_B1),a
        ld   hl,CELLS_A
        ld   (cacur),hl
        ld   hl,CELLS_B
        ld   (canxt),hl
        xor  a
        ld   (caw),a
        ld   hl,512                     ; generations to run this canvas
        ld   (cagen),hl
cagloop:
        call ctlpoll
        or   a
        ret  nz
        call pacedly                    ; software speed brake (per generation)
        call ca_pack                    ; current gen -> scanline caw
        ld   a,(caw)
        add  a,17                       ; bottom of the 240-line window
        out  (SCANREG),a                ; hardware scroll
        call ca_evolve                  ; cur -> nxt
        ld   hl,(cacur)                 ; ping-pong the buffers
        ld   de,(canxt)
        ld   (cacur),de
        ld   (canxt),hl
        ld   a,(caw)
        inc  a
        ld   (caw),a
        ld   hl,(cagen)
        dec  hl
        ld   (cagen),hl
        ld   a,h
        or   l
        jr   nz,cagloop
        xor  a
        out  (SCANREG),a                ; un-scroll before the next mode
        ret

; ca_pack — pack 8-cells/byte from cacur into scanline caw (stride-256 writes)
ca_pack:
        ld   a,(caw)
        ld   c,a                        ; C = scanline (addr low)
        ld   ix,(cacur)
        ld   b,0                        ; B = column 0..79
capcol:
        ld   d,0                        ; packed byte
        ld   e,8
capbit:
        sla  d
        ld   a,(ix+0)
        and  1
        or   d
        ld   d,a                        ; cell0 ends in bit7 (leftmost)
        inc  ix
        dec  e
        jr   nz,capbit
        ld   h,b                        ; addr = (col<<8) | scanline
        ld   l,c
        ld   (hl),d
        inc  b
        ld   a,b
        cp   NCOLS
        jr   nz,capcol
        ret

; ca_evolve — nxt[i] = (rule >> (L*4+C*2+R)) & 1, with zero-guard boundaries
ca_evolve:
        ld   ix,(cacur)
        dec  ix                         ; IX -> cell[-1] (guard)
        ld   de,(canxt)
        ld   bc,NCELLS
caevl:
        ld   a,(ix+0)                   ; left
        add  a,a
        add  a,a                        ; *4
        ld   h,a
        ld   a,(ix+1)                   ; centre
        add  a,a                        ; *2
        add  a,h
        ld   h,a
        ld   a,(ix+2)                   ; right
        add  a,h                        ; idx 0..7
        ld   l,a
        ld   a,(carule)
        inc  l
cashf:
        dec  l
        jr   z,cashfd
        rrca
        jr   cashf
cashfd:
        and  1
        ld   (de),a
        inc  de
        inc  ix
        dec  bc
        ld   a,b
        or   c
        jr   nz,caevl
        ret

; ============================================================================
; mode_chaos — Sierpinski triangle via the chaos game: from the current point,
; jump halfway toward a randomly chosen triangle vertex and plot. No multiply.
; ============================================================================
chaosV:
        dw   320,8                      ; vertex 0 (screen_x, y)
        dw   40,232                     ; vertex 1
        dw   600,232                    ; vertex 2
        dw   320,8                      ; vertex 3 = 0 (so rnd&3 stays in 0..2)
mode_chaos:
        ld   hl,320
        ld   (posx),hl
        ld   hl,120
        ld   (posy),hl
        ld   hl,0c000h
        ld   (lcnt),hl
chaos_lp:
        call rnd16
        and  3
        add  a,a
        add  a,a                        ; *4 bytes per vertex
        ld   e,a
        ld   d,0
        ld   hl,chaosV
        add  hl,de
        ld   c,(hl)
        inc  hl
        ld   b,(hl)
        inc  hl                         ; BC = vertex x
        ld   a,(hl)
        inc  hl
        ld   h,(hl)
        ld   l,a                        ; HL = vertex y
        push hl
        ld   hl,(posx)
        add  hl,bc
        srl  h
        rr   l                          ; x = (x + vx) / 2
        ld   (posx),hl
        pop  bc                         ; BC = vertex y
        push hl
        ld   hl,(posy)
        add  hl,bc
        srl  h
        rr   l                          ; y = (y + vy) / 2
        ld   (posy),hl
        ld   a,l
        pop  hl                         ; HL = screen_x
        call plot
        ld   hl,(lcnt)
        dec  hl
        ld   (lcnt),hl
        ld   a,l
        or   a
        jr   nz,chaos_nx                ; poll + pace every 256 points
        call ctlpoll
        or   a
        ret  nz
        call pacedly
chaos_nx:
        ld   a,h
        or   l
        jr   nz,chaos_lp
        ret

; ============================================================================
; smul — HL = A * C, both signed 8-bit, signed 16-bit product. trashes A,B,C,D,E
; ============================================================================
smul:
        ld   b,0                        ; B = result sign
        or   a
        jp   p,smabs
        neg
        ld   b,1
smabs:
        ld   e,a                        ; E = |A| (multiplicand)
        ld   a,c
        or   a
        jp   p,smc
        neg
        ld   c,a
        ld   a,b
        xor  1
        ld   b,a
smc:
        ld   d,0                         ; DE = |A|
        ld   a,c                         ; A = |C| (multiplier, MSB-first)
        ld   hl,0
        ld   c,8
smlp:
        add  hl,hl
        rlca
        jr   nc,smnb
        add  hl,de
smnb:
        dec  c
        jr   nz,smlp
        bit  0,b
        ret  z
        ld   a,h                         ; negate HL
        cpl
        ld   h,a
        ld   a,l
        cpl
        ld   l,a
        inc  hl
        ret

; ============================================================================
; mode_phyllo — phyllotaxis (sunflower): point n at angle n*goldenAngle, radius
; ~sqrt(n). Golden angle = 137.5deg ~= 98/256 turn. radius via incremental
; integer sqrt (no division). x=320+r*cos>>7, y=120+r*sin>>7.
; ============================================================================
mode_phyllo:
        xor  a
        ld   (pha),a
        ld   (phr),a
        inc  a
        ld   (phrs),a                   ; radius-step threshold = 1
        ld   hl,2400h                   ; ~9200 seeds
        ld   (lcnt),hl
phyl_lp:
        ld   a,(phrs)                   ; advance radius as floor(sqrt(n))
        dec  a
        ld   (phrs),a
        jr   nz,phyl_ang
        ld   a,(phr)
        cp   110
        jr   nc,phyl_ang                ; cap radius
        inc  a
        ld   (phr),a
        add  a,a
        inc  a                          ; 2r+1
        ld   (phrs),a
phyl_ang:
        ld   a,(pha)
        add  a,98                       ; golden-angle step
        ld   (pha),a
        add  a,40h                      ; cosine phase
        call sinlk
        ld   c,a
        ld   a,(phr)
        call smul                       ; HL = r*cos
        ld   b,7
phyl_sx:
        sra  h
        rr   l
        djnz phyl_sx
        ld   de,320
        add  hl,de
        push hl                         ; screen_x
        ld   a,(pha)
        call sinlk                      ; sin(angle)
        ld   c,a
        ld   a,(phr)
        call smul                       ; HL = r*sin
        ld   b,7
phyl_sy:
        sra  h
        rr   l
        djnz phyl_sy
        ld   de,120
        add  hl,de                      ; y
        ld   a,l
        pop  hl                         ; screen_x
        call plot
        ld   hl,(lcnt)
        dec  hl
        ld   (lcnt),hl
        ld   a,l
        and  7fh                        ; poll + pace every 128 seeds
        jr   nz,phyl_nx
        call ctlpoll
        or   a
        ret  nz
        call pacedly
phyl_nx:
        ld   a,h
        or   l
        jr   nz,phyl_lp
        ret

; ============================================================================
; mode_rose — rhodonea (rose) curve: r = sin(k*theta) plotted in polar, giving
; k- or 2k-petal flowers. Reliable (not chaos-sensitive); random k per canvas.
;   x = 320 + (r*cos theta)>>7 ;  y = 120 + (r*sin theta)>>7
; mq: 0=k, 1=r. theta is the 16-bit accumulator px1; pha = theta index.
; ============================================================================
mode_rose:
        call rnd16
        and  7
        add  a,2                        ; k = 2..9 petals
        ld   (mq),a
        ld   hl,0
        ld   (px1),hl                   ; theta accumulator
        ld   hl,0c000h
        ld   (lcnt),hl
rose_lp:
        ld   hl,(px1)
        ld   de,0060h
        add  hl,de
        ld   (px1),hl
        ld   a,h                        ; theta index
        ld   (pha),a
        ld   c,a                        ; r = sin(k*theta)
        ld   a,(mq)
        call smul
        ld   a,l
        call sinlk
        ld   (mq+1),a                   ; r (signed)
        ld   a,(pha)
        add  a,40h
        call sinlk                      ; cos(theta)
        ld   c,a
        ld   a,(mq+1)
        call smul                       ; r*cos
        ld   b,7
rose_sx:
        sra  h
        rr   l
        djnz rose_sx
        ld   de,320
        add  hl,de
        push hl
        ld   a,(pha)
        call sinlk                      ; sin(theta)
        ld   c,a
        ld   a,(mq+1)
        call smul                       ; r*sin
        ld   b,7
rose_sy:
        sra  h
        rr   l
        djnz rose_sy
        ld   de,120
        add  hl,de
        ld   a,l
        pop  hl
        call plot
        ld   hl,(lcnt)
        dec  hl
        ld   (lcnt),hl
        ld   a,l
        or   a
        jr   nz,rose_nx
        call ctlpoll
        or   a
        ret  nz
        call pacedly
rose_nx:
        ld   a,h
        or   l
        jp   nz,rose_lp
        ret

; ============================================================================
; mode_truchet — Truchet tiles: each 16x16 cell gets a random diagonal (/ or
; \); they join into flowing labyrinthine paths. mq: 0/1=cx 2=cy 3=dir 4=i
; 5=col-count 6=row-count.
; ============================================================================
mode_truchet:
        xor  a
        ld   (mq+2),a                   ; cy = 0
        ld   a,15
        ld   (mq+6),a                   ; 15 rows
tru_row:
        ld   hl,0
        ld   (mq),hl                    ; cx = 0
        ld   a,40
        ld   (mq+5),a                   ; 40 columns
tru_col:
        call rnd16
        and  1
        ld   (mq+3),a                   ; diagonal direction
        xor  a
        ld   (mq+4),a                   ; i = 0
tru_pix:
        ld   a,(mq+3)
        or   a
        ld   a,(mq+4)                   ; i (flags still from dir)
        jr   nz,tru_bs
        ld   b,a                        ; slash: xoff = 15 - i
        ld   a,15
        sub  b
tru_bs:
        ld   e,a                        ; backslash falls through: xoff = i
        ld   d,0
        ld   hl,(mq)
        add  hl,de                      ; screen_x = cx + xoff
        ld   a,(mq+2)
        ld   b,a
        ld   a,(mq+4)
        add  a,b                        ; y = cy + i
        call plot
        ld   a,(mq+4)
        inc  a
        ld   (mq+4),a
        cp   16
        jr   nz,tru_pix
        ld   hl,(mq)
        ld   de,16
        add  hl,de
        ld   (mq),hl                    ; cx += 16
        ld   a,(mq+5)
        dec  a
        ld   (mq+5),a
        jp   nz,tru_col
        ld   a,(mq+2)
        add  a,16
        ld   (mq+2),a                   ; cy += 16
        call ctlpoll
        or   a
        ret  nz
        call pacedly
        ld   a,(mq+6)
        dec  a
        ld   (mq+6),a
        jp   nz,tru_row
        ret

; ============================================================================
; mode_walk — Brownian web: many walkers each random-walk *with momentum*
; (mostly continue, sometimes turn), leaving a trail. The drifting meanders
; weave an organic, smoke-like tangle. mq: 0=wx 1=wy 2=walker-count 3=dir.
; Drawn at screen_x = wx+192 (256-wide centred band).
; ============================================================================
mode_walk:
        ld   a,28
        ld   (mq+2),a                   ; walkers
walk_spawn:
        call rnd16
        ld   (mq),a                     ; wx
        call rnd16
        ld   (mq+1),a                   ; wy
        call rnd16
        and  3
        ld   (mq+3),a                   ; initial direction
        ld   hl,300h                    ; steps per walker
        ld   (lcnt),hl
walk_step:
        ld   a,(mq)
        ld   l,a
        ld   h,0
        ld   de,192
        add  hl,de
        ld   a,(mq+1)
        call plot
        call rnd16                      ; 1-in-4 chance to turn (momentum)
        and  3
        jr   nz,walk_keep
        call rnd16
        and  3
        ld   (mq+3),a
walk_keep:
        ld   a,(mq+3)
        or   a
        jr   z,wlk_l
        dec  a
        jr   z,wlk_r
        dec  a
        jr   z,wlk_u
        ld   a,(mq+1)
        inc  a
        ld   (mq+1),a
        jr   wlk_mv
wlk_u:
        ld   a,(mq+1)
        dec  a
        ld   (mq+1),a
        jr   wlk_mv
wlk_l:
        ld   a,(mq)
        dec  a
        ld   (mq),a
        jr   wlk_mv
wlk_r:
        ld   a,(mq)
        inc  a
        ld   (mq),a
wlk_mv:
        ld   hl,(lcnt)
        dec  hl
        ld   (lcnt),hl
        ld   a,l
        or   a
        jr   nz,wlk_nx
        call ctlpoll
        or   a
        ret  nz
        call pacedly
wlk_nx:
        ld   a,h
        or   l
        jp   nz,walk_step
        ld   a,(mq+2)
        dec  a
        ld   (mq+2),a
        jp   nz,walk_spawn
        ret

; ============================================================================
; mode_mult — multiplication-table moiré: each byte = ((col+ox)*(scan+oy))&255,
; the 8 pixels being that product's bit pattern. Random offsets per canvas
; shift the interweaving lattice. Direct video writes (no plot). mq:0=ox 1=oy.
; ============================================================================
mode_mult:
        call rnd16
        ld   (mq),a                     ; ox
        call rnd16
        ld   (mq+1),a                   ; oy
        ld   b,0                        ; col
mul_col:
        ld   c,0                        ; scan
mul_row:
        push bc
        ld   a,b
        ld   hl,mq
        add  a,(hl)                     ; col + ox
        ld   e,a
        ld   a,c
        ld   hl,mq+1
        add  a,(hl)                     ; scan + oy
        ld   c,a
        ld   a,e
        call smul                       ; (col+ox)*(scan+oy)
        ld   a,l
        pop  bc
        ld   h,b                        ; video addr = col*256 + scan
        ld   l,c
        ld   (hl),a
        inc  c
        ld   a,c
        cp   240
        jr   nz,mul_row
        push bc
        call ctlpoll
        or   a
        jr   nz,mul_ab
        call pacedly
        pop  bc
        inc  b
        ld   a,b
        cp   NCOLS
        jr   nz,mul_col
        ret
mul_ab:
        pop  bc
        ret

; ============================================================================
; mode_plasma — smooth sine interference field. Per pixel: v = sin(x-phase) +
; sin(y-phase) + sin(diagonal); lit where v >= 0, giving flowing organic bands.
; No per-pixel multiply: x-phase steps by fx, diagonal by 1. State in memory.
; ============================================================================
mode_plasma:
        call rnd16
        and  3
        add  a,1
        ld   (pfx),a
        call rnd16
        and  3
        add  a,1
        ld   (pfy),a
        xor  a
        ld   (pscan),a
plr_row:
        ld   a,(pfy)                    ; sy = sin(scan*fy)
        ld   c,a
        ld   a,(pscan)
        call smul
        ld   a,l
        call sinlk
        ld   (psy),a
        xor  a
        ld   (pix),a                    ; x-phase = 0
        ld   a,(pscan)
        ld   (pidg),a                   ; diagonal phase = scan
        ld   a,(pscan)
        ld   l,a                        ; remember scan in L? no - keep in pscan
        xor  a
        ld   (pcol),a
plr_col:
        ld   a,8
        ld   (pbit),a
        xor  a
        ld   (pacc),a
plr_bit:
        ld   a,(pix)
        call sinlk
        ld   b,a                        ; vx
        ld   a,(pidg)
        call sinlk
        ld   c,a                        ; vd
        ld   a,(psy)                    ; HL = signext(sy)
        ld   l,a
        add  a,a
        sbc  a,a
        ld   h,a
        ld   a,b                        ; + signext(vx)
        ld   e,a
        add  a,a
        sbc  a,a
        ld   d,a
        add  hl,de
        ld   a,c                        ; + signext(vd)
        ld   e,a
        add  a,a
        sbc  a,a
        ld   d,a
        add  hl,de                      ; HL = vx+vd+sy (signed)
        ld   a,(pacc)
        add  a,a                        ; pacc <<= 1
        bit  7,h                        ; sign: negative -> pixel 0
        jr   nz,plr_z
        inc  a
plr_z:
        ld   (pacc),a
        ld   a,(pix)                    ; advance x-phase by fx
        ld   hl,pfx
        add  a,(hl)
        ld   (pix),a
        ld   a,(pidg)
        inc  a
        ld   (pidg),a
        ld   a,(pbit)
        dec  a
        ld   (pbit),a
        jr   nz,plr_bit
        ld   a,(pcol)                   ; write byte at (col, scan)
        ld   h,a
        ld   a,(pscan)
        ld   l,a
        ld   a,(pacc)
        ld   (hl),a
        ld   a,(pcol)
        inc  a
        ld   (pcol),a
        cp   NCOLS
        jp   nz,plr_col
        call ctlpoll
        or   a
        ret  nz
        call pacedly
        ld   a,(pscan)
        inc  a
        ld   (pscan),a
        cp   240
        jp   nz,plr_row
        ret

; ============================================================================
; mode_ripple — two-source wave interference. Each byte is on/off by the XOR of
; two concentric Manhattan-distance ring fields, giving classic ripple-tank
; moire. Centres (pfx,pfy)=c1col,c1scan (psy,pscan)=c2. Direct video writes.
; ============================================================================
mode_ripple:
        call rnd16
        and  3fh
        add  a,8
        ld   (pfx),a                    ; c1 col
        call rnd16
        and  7fh
        add  a,50
        ld   (pfy),a                    ; c1 scan
        call rnd16
        and  3fh
        add  a,8
        ld   (psy),a                    ; c2 col
        call rnd16
        and  7fh
        add  a,50
        ld   (pscan),a                  ; c2 scan
        ld   b,0
rip_col:
        ld   c,0
rip_row:
        push bc
        ld   a,(pfx)                    ; ring of centre 1
        ld   (mq),a
        ld   a,(pfy)
        ld   (mq+1),a
        call ringv
        ld   (mq+4),a
        ld   a,(psy)                    ; ring of centre 2
        ld   (mq),a
        ld   a,(pscan)
        ld   (mq+1),a
        call ringv
        ld   hl,mq+4
        xor  (hl)                       ; XOR the two ring fields
        jr   z,rip_off
        ld   a,0ffh
        jr   rip_wr
rip_off:
        xor  a
rip_wr:
        ld   e,a                        ; byte value
        pop  bc
        ld   h,b
        ld   l,c
        ld   (hl),e
        inc  c
        ld   a,c
        cp   240
        jr   nz,rip_row
        push bc
        call ctlpoll
        or   a
        jr   nz,rip_ab
        call pacedly
        pop  bc
        inc  b
        ld   a,b
        cp   NCOLS
        jr   nz,rip_col
        ret
rip_ab:
        pop  bc
        ret

; ringv — B=col, C=scan, (mq)=ccol, (mq+1)=cscan. Returns A = ring bit (0/1)
; from sin(Manhattan distance). trashes A,D,E,H,L (preserves B,C)
ringv:
        ld   a,b                        ; dx = col - ccol
        ld   hl,mq
        sub  (hl)
        ld   e,a                        ; signext dx -> HL
        add  a,a
        sbc  a,a
        ld   d,a
        ex   de,hl
        add  hl,hl                      ; dx*8
        add  hl,hl
        add  hl,hl
        bit  7,h
        jr   z,rv_dxp
        ld   a,h
        cpl
        ld   h,a
        ld   a,l
        cpl
        ld   l,a
        inc  hl
rv_dxp:
        push hl                         ; |dx*8|
        ld   l,c                        ; dy = scan - cscan (16-bit)
        ld   h,0
        ld   a,(mq+1)
        ld   e,a
        ld   d,0
        or   a
        sbc  hl,de
        bit  7,h
        jr   z,rv_dyp
        ld   a,h
        cpl
        ld   h,a
        ld   a,l
        cpl
        ld   l,a
        inc  hl
rv_dyp:
        pop  de                         ; DE = |dx*8|
        add  hl,de                      ; Manhattan distance
        add  hl,hl
        add  hl,hl                      ; d*4 -> ~64px ring spacing
        ld   a,l                        ; phase = (d*4) mod 256
        call sinlk
        rla                             ; sign -> carry
        ld   a,0
        ret  c
        inc  a
        ret

; ============================================================================
; mode_mandel — the Mandelbrot set, escape-time, one c per byte (80x240).
; Q4.4 fixed point: z=z^2+c, escape when |z|^2 > 4. In-set pixels solid; the
; exterior is banded by escape-iteration parity. mq: 0=cr 1=ci 2=zr 3=zi
; 4=iter 5=col 6=scan. pfy/psy = Q4.4 scratch.
; ============================================================================
mode_mandel:
        xor  a
        ld   (mq+5),a                   ; col = 0
mb_col:
        ld   a,(mq+5)                   ; cr = (col*10 >> 4) - 35
        ld   c,10
        call smul
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l
        ld   a,l
        sub  35
        ld   (mq),a
        xor  a
        ld   (mq+6),a                   ; scan = 0
mb_scan:
        ld   a,(mq+6)                   ; ci = (scan*3 >> 4) - 21
        ld   c,3
        call smul
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l
        ld   a,l
        sub  21
        ld   (mq+1),a
        xor  a
        ld   (mq+2),a                   ; zr = 0
        ld   (mq+3),a                   ; zi = 0
        ld   a,16
        ld   (mq+4),a                   ; iteration budget
mb_it:
        ld   a,(mq+2)                   ; zr^2 (Q8.8)
        ld   c,a
        call smul
        push hl
        ld   a,(mq+3)                   ; zi^2
        ld   c,a
        call smul
        pop  de
        push de
        push hl
        add  hl,de                      ; |z|^2 = zr^2 + zi^2
        ld   a,h
        cp   4                          ; >= 4.0 (1024 in Q8.8) -> escape
        jr   nc,mb_esc
        pop  hl                         ; zi^2 -> Q4.4
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l
        ld   a,l
        ld   (pfy),a                    ; zi2
        pop  hl                         ; zr^2 -> Q4.4
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l
        ld   a,l
        ld   hl,pfy
        sub  (hl)                       ; zr2 - zi2
        ld   hl,mq
        add  a,(hl)                     ; + cr
        ld   (psy),a                    ; new zr
        ld   a,(mq+2)                   ; zr*zi (signed)
        ld   c,a
        ld   a,(mq+3)
        call smul
        sra  h
        rr   l
        sra  h
        rr   l
        sra  h
        rr   l
        sra  h
        rr   l                          ; (zr*zi) >> 4
        add  hl,hl                      ; * 2
        ld   a,l
        ld   hl,mq+1
        add  a,(hl)                     ; + ci
        ld   (mq+3),a                   ; new zi
        ld   a,(psy)
        ld   (mq+2),a                   ; new zr
        ld   a,(mq+4)
        dec  a
        ld   (mq+4),a
        jp   nz,mb_it
        ld   e,0ffh                     ; never escaped -> in the set (solid)
        jr   mb_put
mb_esc:
        pop  hl                         ; discard zi^2, zr^2
        pop  hl
        ld   e,0                        ; exterior: black (set stays solid)
mb_put:
        ld   a,(mq+5)
        ld   h,a
        ld   a,(mq+6)
        ld   l,a
        ld   (hl),e
        ld   a,(mq+6)
        inc  a
        ld   (mq+6),a
        cp   240
        jp   nz,mb_scan
        call ctlpoll
        or   a
        ret  nz
        call pacedly
        ld   a,(mq+5)
        inc  a
        ld   (mq+5),a
        cp   NCOLS
        jp   nz,mb_col
        ret

; ============================================================================
; mode_life — Conway's Game of Life on an 80x48 grid (each cell an 8x5 block),
; random soup seed, ~40 generations. Double-buffered with a 1-cell dead border
; (stride 82) so neighbour sums need no edge tests. mq:0=row 1=col 2=scanbase.
; ============================================================================
mode_life:
        ld   hl,LIFEA                   ; clear both buffers (incl. borders)
        ld   bc,4100
        call lclr
        ld   hl,LIFEB
        ld   bc,4100
        call lclr
        ld   hl,LIFEA
        ld   (lcur),hl
        ld   hl,LIFEB
        ld   (lnxt),hl
        ld   ix,(lcur)                  ; seed current generation: random soup
        ld   de,LSTR+1
        add  ix,de
        ld   a,LIFEH
        ld   (mq),a
lf_srow:
        ld   a,LIFEW
        ld   (mq+1),a
lf_scell:
        call rnd16
        and  1
        ld   (ix+0),a
        inc  ix
        ld   a,(mq+1)
        dec  a
        ld   (mq+1),a
        jr   nz,lf_scell
        inc  ix
        inc  ix
        ld   a,(mq)
        dec  a
        ld   (mq),a
        jr   nz,lf_srow
        ld   a,40
        ld   (lgen),a
lf_gen:
        ld   ix,(lcur)                  ; --- evolve cur -> nxt ---
        ld   de,LSTR+1
        add  ix,de
        ld   hl,(lnxt)
        ld   de,LSTR+1
        add  hl,de
        ld   a,LIFEH
        ld   (mq),a
lf_grow:
        ld   a,LIFEW
        ld   (mq+1),a
lf_gcell:
        ld   a,(ix-83)
        add  a,(ix-82)
        add  a,(ix-81)
        add  a,(ix-1)
        add  a,(ix+1)
        add  a,(ix+81)
        add  a,(ix+82)
        add  a,(ix+83)
        cp   3
        jr   z,lf_birth
        cp   2
        jr   nz,lf_die
        ld   a,(ix+0)
        or   a
        jr   z,lf_die
lf_birth:
        ld   (hl),1
        jr   lf_gadv
lf_die:
        ld   (hl),0
lf_gadv:
        inc  ix
        inc  hl
        ld   a,(mq+1)
        dec  a
        ld   (mq+1),a
        jr   nz,lf_gcell
        inc  ix
        inc  ix
        inc  hl
        inc  hl
        ld   a,(mq)
        dec  a
        ld   (mq),a
        jp   nz,lf_grow
        ld   ix,(lnxt)                  ; --- draw nxt ---
        ld   de,LSTR+1
        add  ix,de
        ld   a,LIFEH
        ld   (mq),a
        xor  a
        ld   (mq+2),a
lf_drow:
        ld   b,0
lf_dcell:
        ld   a,(ix+0)
        or   a
        jr   z,lf_doff
        ld   a,0ffh
        jr   lf_dset
lf_doff:
        xor  a
lf_dset:
        ld   c,a
        ld   a,(mq+2)
        ld   l,a
        ld   h,b
        ld   (hl),c
        inc  l
        ld   (hl),c
        inc  l
        ld   (hl),c
        inc  l
        ld   (hl),c
        inc  l
        ld   (hl),c
        inc  ix
        inc  b
        ld   a,b
        cp   LIFEW
        jr   nz,lf_dcell
        inc  ix
        inc  ix
        ld   a,(mq+2)
        add  a,5
        ld   (mq+2),a
        ld   a,(mq)
        dec  a
        ld   (mq),a
        jp   nz,lf_drow
        ld   hl,(lcur)                  ; swap buffers
        ld   de,(lnxt)
        ld   (lcur),de
        ld   (lnxt),hl
        call ctlpoll
        or   a
        ret  nz
        call pacedly
        ld   a,(lgen)
        dec  a
        ld   (lgen),a
        jp   nz,lf_gen
        ret
lclr:
        ld   (hl),0
        inc  hl
        dec  bc
        ld   a,b
        or   c
        jr   nz,lclr
        ret

; ============================================================================
; hold — pause (~17 s at 4 MHz) so a finished canvas can be admired before the
; gallery advances. trashes A,B,C,D
; ============================================================================
hold:
        ld   d,20h
hold_o:
        call ctlpoll                    ; stay responsive to keys while admiring
        or   a
        ret  nz
        call pacedly                    ; pace-scaled admire (matters under turbo)
        ld   bc,0                        ; + a fixed slice so native still lingers
hold_i:
        dec  bc
        ld   a,b
        or   c
        jr   nz,hold_i
        dec  d
        jr   nz,hold_o
        ret

; ============================================================================
; pacedly — software speed brake. Burns paceLvl * ~1.7M T-states. The host
; emulator's turbo has no throttle a Z80 program can read, so GREENFIELD paces
; itself: run NorthMac in turbo for headroom and dial the visual speed here.
; paceLvl 0 = flat out (use this in native 4 MHz mode). Preserves C,D,E,H,L.
; ============================================================================
pacedly:
        ld   a,(paceLvl)
        or   a
        ret  z
        ld   b,a
pd_o:
        push bc
        ld   bc,0                        ; 65536 inner iterations (~1.7M T-states)
pd_i:
        dec  bc
        ld   a,b
        or   c
        jr   nz,pd_i
        pop  bc
        djnz pd_o
        ret

; ============================================================================
; ctlpoll — non-blocking keyboard poll. If a key is waiting, read and act on
; it. Returns A = command (0 = keep painting; nonzero = abort this canvas).
; Digit keys set `mode`. trashes A,B,C
; ============================================================================
ctlpoll:
        in   a,(0e0h)                   ; status reg 1, bit0 = key available
        and  1
        ret  z
        call getkey
ctlkey:
        cp   020h                       ; SPACE -> new canvas, same mode
        jr   z,ctl_skip
        cp   050h                       ; 'P' -> pause
        jr   z,ctl_pause
        cp   070h                       ; 'p'
        jr   z,ctl_pause
        cp   02bh                       ; '+' -> faster (less brake)
        jr   z,ctl_fast
        cp   03dh                       ; '=' -> faster
        jr   z,ctl_fast
        cp   02dh                       ; '-' -> slower (more brake)
        jr   z,ctl_slow
        cp   030h                       ; '0'..'9' -> select mode 0..9
        jr   c,ctl_none
        cp   03ah
        jr   nc,ctl_none
        sub  030h
        cp   NMODES                     ; ignore if no such mode
        jr   nc,ctl_none
        ld   (mode),a
        ld   a,2
        ld   (cmd),a
        ret
ctl_skip:
        ld   a,1
        ld   (cmd),a
        ret
ctl_pause:
        call getkey                     ; freeze the canvas until any key...
        jr   ctlkey                     ; ...then act on that key (resume/select)
ctl_fast:
        ld   a,(paceLvl)                ; speed up: don't abort, just retune
        or   a
        jr   z,ctl_none
        dec  a
        ld   (paceLvl),a
        xor  a
        ret
ctl_slow:
        ld   a,(paceLvl)
        cp   60
        jr   nc,ctl_none
        inc  a
        ld   (paceLvl),a
        xor  a
        ret
ctl_none:
        xor  a
        ret

; ============================================================================
; getkey — blocking read of one keyboard character, using the PROM's nibble +
; ack-toggle handshake (works on the emulator and on real hardware). trashes
; A,B,C; returns the 7-bit code in A.
; ============================================================================
getkey:
        in   a,(0d0h)                   ; wait for keyboard data flag (bit6)
        bit  6,a
        jr   z,getkey
        ld   b,a                        ; remember ack state
        ld   a,19h                      ; cmd 1: present low nibble
        out  (0f8h),a
gk1:
        in   a,(0d0h)
        xor  b
        jp   p,gk1                      ; wait for ack (bit7) to flip
        in   a,(0d0h)
        and  0fh
        ld   c,a                        ; low nibble
        ld   a,1ah                      ; cmd 2: present high nibble (clears flag)
        out  (0f8h),a
gk2:
        in   a,(0d0h)
        xor  b
        jp   m,gk2
        in   a,(0d0h)
        add  a,a
        add  a,a
        add  a,a
        add  a,a                        ; high nibble << 4
        or   c
        ret

; ============================================================================
; chime — a short, seed-derived signature tune played as each canvas begins,
; so every piece announces itself. Drives the speaker (IOCTL bit 6). The notes
; come from the same LFSR that paints the art, so sound and image share a seed.
; trashes A,B,C
; ============================================================================
chime:
        ld   b,6                        ; six notes
chnote:
        push bc
        call rnd16
        and  3fh
        add  a,50h                      ; pitch 0x50..0x8F
        ld   b,a
        ld   c,28h                      ; note length (square-wave periods)
        call beep
        pop  bc
        djnz chnote
        ret

; beep — B = pitch (larger = lower), C = duration. Square-wave on the speaker.
; Keeps display on (bit5 = 0); preserves B. trashes A,C
beep:
        ld   a,50h                      ; speaker high (bit6; bit4 held — real
        out  (IOCTL),a                  ;   hardware freezes I/O with bit4 low)
        ld   a,b
beep_h:
        dec  a
        jr   nz,beep_h
        ld   a,10h                      ; speaker low (bit4 still held)
        out  (IOCTL),a
        ld   a,b
beep_l:
        dec  a
        jr   nz,beep_l
        dec  c
        jr   nz,beep
        ret

; ============================================================================
; sign — every finished canvas is a signed edition: clear a strip along the
; bottom and render "GREENFIELD" + the 4-hex seed in the 5x7 font, so each
; piece is identified and reproducible. trashes A,B,C,D,E,H,L
; ============================================================================
sign:
        ld   b,0                        ; clear a 20-col x 10-line strip (legible bg)
sgnc:
        ld   h,b
        ld   l,213
        ld   e,11
sgnr:
        ld   (hl),0
        inc  l
        dec  e
        jr   nz,sgnr
        inc  b
        ld   a,b
        cp   20
        jr   nz,sgnc

        ld   a,215
        ld   (txty),a
        ld   b,1
        ld   hl,str_title
        call puts                       ; "GREENFIELD" (cols 1..10)
        inc  b                          ; gap
        ld   a,(cseed+1)
        call puthex                     ; seed high byte
        ld   a,(cseed)
        call puthex                     ; seed low byte
        inc  b                          ; gap, then "S" + pace level
        ld   a,'S'
        call putc
        inc  b
        ld   a,(paceLvl)
        call puthex
        ret

; puts — draw 0-terminated string at HL from column B (advances B). trashes all
puts:
        ld   a,(hl)
        or   a
        ret  z
        push hl
        call putc
        pop  hl
        inc  hl
        inc  b
        jr   puts

; puthex — draw byte A as two hex digits at column B (advances B by 2)
puthex:
        push af
        rrca
        rrca
        rrca
        rrca
        and  0fh
        call hexnib
        call putc
        inc  b
        pop  af
        and  0fh
        call hexnib
        call putc
        inc  b
        ret

; hexnib — A (0..15) -> ASCII hex char
hexnib:
        cp   10
        jr   c,hexn0
        add  a,'A'-10
        ret
hexn0:
        add  a,'0'
        ret

; putc — draw the glyph for char A at column B, top scanline txty (OR over the
; art). Recognises space, 0-9, A-Z. trashes A,C,D,E,H,L (preserves B)
putc:
        cp   ' '
        ret  z
        cp   '0'
        ret  c
        cp   '9'+1
        jr   c,pc_dig
        cp   'A'
        ret  c
        cp   'Z'+1
        ret  nc
        sub  'A'-10                     ; A..Z -> 10..35
        jr   pc_idx
pc_dig:
        sub  '0'                        ; 0..9
pc_idx:
        ld   l,a                        ; HL = font + glyph*7
        ld   h,0
        ld   d,h
        ld   e,l
        add  hl,hl
        add  hl,hl
        add  hl,de
        add  hl,de
        add  hl,de                      ; *7
        ld   de,font
        add  hl,de
        ld   a,(txty)
        ld   c,a                        ; C = scanline
        ld   e,7
pc_row:
        ld   a,(hl)
        inc  hl
        push hl
        push bc
        ld   d,a                        ; glyph row pattern
        ld   h,b                        ; video addr = (col<<8)|scanline
        ld   l,c
        ld   a,(hl)
        or   d
        ld   (hl),a
        pop  bc
        pop  hl
        inc  c
        dec  e
        jr   nz,pc_row
        ret

str_title:
        db   "GREENFIELD",0

; ============================================================================
; step — advance the current particle one step along the flow field and plot.
; Domain-warped flow field (the trick that turns a regular vortex lattice into
; organic, turbulent streams): each axis's field index is perturbed by the
; *other* axis's sine before the final lookup.
;   xi = posx>>6 ; yi = posy>>6
;   angle = sin(xi + sin(yi)/2) + sin(yi + sin(xi)/2) + drift   (mod 256)
;   posx += cos(angle) ; posy += sin(angle)        (signed sub-pixel step)
; trashes A,B,C,D,E,H,L
; ============================================================================
step:
        ; field indices from position ------------------------------------
        ld   hl,(posx)
        add  hl,hl
        add  hl,hl                      ; H = (posx>>6)&0xFF
        ld   a,h
        ld   (tmpxi),a
        ld   hl,(posy)
        add  hl,hl
        add  hl,hl                      ; H = (posy>>6)&0xFF
        ld   a,h
        ld   (tmpyi),a

        ; warp terms: sin(xi)/2 and sin(yi)/2 ----------------------------
        ld   a,(tmpxi)
        call sinlk
        sra  a                          ; sin(xi)/2 (signed)
        ld   (tmpsx),a
        ld   a,(tmpyi)
        call sinlk
        sra  a                          ; sin(yi)/2
        ld   b,a

        ; angle = sin(xi + sin(yi)/2) + sin(yi + sin(xi)/2) + drift -------
        ld   a,(tmpxi)
        add  a,b                        ; xi + sin(yi)/2
        call sinlk
        ld   c,a                        ; sin(warped xi)
        ld   a,(tmpsx)
        ld   hl,tmpyi
        add  a,(hl)                     ; yi + sin(xi)/2
        call sinlk                      ; sin(warped yi)
        add  a,c
        ld   hl,drift
        add  a,(hl)                     ; -> angle (mod 256)
        ld   (tmpa),a

        call sinlk                      ; A = sin(angle) = dy step
        ld   c,a
        ld   a,(tmpa)
        add  a,40h                      ; angle + 64  -> cosine phase
        call sinlk                      ; A = cos(angle) = dx step

        ; posx += signext(dx) --------------------------------------------
        ld   e,a
        add  a,a
        sbc  a,a                        ; A = 0x00/0xFF = sign of dx
        ld   d,a
        ld   hl,(posx)
        add  hl,de
        ld   (posx),hl
        ; posy += signext(dy)
        ld   a,c
        ld   e,a
        add  a,a
        sbc  a,a
        ld   d,a
        ld   hl,(posy)
        add  hl,de
        ld   (posy),hl

        ; screen_x = (posx>>7) + 64  (centres the 512-wide field in 640) ---
        ld   hl,(posx)
        add  hl,hl                      ; carry = posx bit15 (the 256s bit)
        ld   l,h
        ld   h,0
        jr   nc,noxhi
        inc  h                          ; pixel_x bit8
noxhi:
        ld   de,64
        add  hl,de                      ; HL = screen_x (64..575)

        ; py = posy>>8 ; cull off-screen-bottom -------------------------
        ld   a,(posyh)
        cp   240
        ret  nc                         ; moved off canvas this step: don't plot
        ; fall into plot with HL=screen_x, A=py
        ; (plot returns to step's caller)

; ============================================================================
; plot — set the pixel at screen_x (HL, 0..639) and y (A, 0..239)
;   column = x>>3 (-> addr high), scan = y (-> addr low), bit7 = leftmost.
; trashes A,B,C,H,L
; ============================================================================
plot:
        ld   (tmpa),a                   ; stash y
        ld   a,l
        and  7
        ld   b,a
        ld   a,80h                      ; mask = 0x80 >> (x & 7)
        inc  b
pmask:
        dec  b
        jr   z,pmaskd
        rrca
        jr   pmask
pmaskd:
        ld   c,a                        ; C = pixel mask
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l                          ; HL = x>>3 ; L = column (0..79), H = 0
        ld   h,l                        ; addr high = column
        ld   a,(tmpa)
        ld   l,a                        ; addr low = scan ; HL = col*256 + scan
        ld   a,(hl)
        or   c
        ld   (hl),a                     ; OR the pixel in (trails accumulate)
        ret

; ============================================================================
; getpix — test the pixel at x (HL, 0..639), y (A). Returns NZ if set, Z if
; clear. trashes A,B,C,H,L
; ============================================================================
getpix:
        ld   c,a                        ; scan
        ld   a,l
        and  7
        ld   b,a
        ld   a,80h
        inc  b
gpm:
        dec  b
        jr   z,gpmd
        rrca
        jr   gpm
gpmd:
        ld   b,a                        ; B = mask
        srl  h
        rr   l
        srl  h
        rr   l
        srl  h
        rr   l                          ; HL = column
        ld   h,l
        ld   l,c                        ; HL = col*256 + scan
        ld   a,(hl)
        and  b
        ret

; ============================================================================
; sinlk — A := sintab[A]  (signed). trashes D,E,H,L
; ============================================================================
sinlk:
        ld   hl,sintab
        ld   e,a
        ld   d,0
        add  hl,de
        ld   a,(hl)
        ret

; ============================================================================
; rnd16 — 16-bit Galois LFSR (poly 0xB400). returns A = low byte. trashes H,L
; ============================================================================
rnd16:
        ld   hl,(prng)
        srl  h
        rr   l
        jr   nc,rnd_nf
        ld   a,h
        xor  0b4h
        ld   h,a
rnd_nf:
        ld   (prng),hl
        ld   a,l
        ret

; ============================================================================
; cls — clear the full 80x256 framebuffer to black. trashes A,B,H,L
; ============================================================================
cls:
        ld   b,0
clscol:
        ld   h,b
        ld   l,0
        xor  a
clsrow:
        ld   (hl),a
        inc  l
        jr   nz,clsrow
        inc  b
        ld   a,b
        cp   NCOLS
        jr   nz,clscol
        ret

; ============================================================================
        include "sintab.inc"
        include "font.inc"
