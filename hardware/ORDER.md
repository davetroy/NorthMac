# NS-WSG — PCBWay Order Package

*Prepared 2026-08-31. Both boards DRC-clean (KiCad 10: 0 violations,
0 unconnected). Silk carries: © 2026 David Troy, in memory of Stephen Troy.*

## Files

| board | gerbers | size | qty suggestion |
|-------|---------|------|----------------|
| Bus riser | `riser_fab.zip` | 46.5 × 63.5 mm (1.83" × 2.50") | 10 (min) |
| NS-WSG card | `card_fab.zip` | 143.1 × 80.0 mm (5.63" × 3.15", incl. tab) | 5 |

## PCBWay parameters (both boards)

- Layers: **2**, thickness: **1.6 mm**, copper: 1 oz
- Solder mask: green (or taste), silkscreen: white
- Surface finish: **HASL** (lead-free) — with the gold-finger option the
  edge fingers get plated regardless; ENIG upgrade optional
- **Gold fingers: YES** + **bevel: YES** (20°) — per PCBWay these add no
  extra cost on prototype orders; expect an engineering-review question
  about the protruding tab, answer: bevel the tab edge only
- Min track/space in design: 0.25 mm / 0.2 mm; min drill 0.3 mm (vias) —
  well inside standard capability
- Castellations/impedance/etc.: none

**Pre-upload checklist**
1. ~~1:1 print of the edge fingers vs a real SIO card~~ — done, exact match
2. Riser goes in the machine before any card gets soldered (geometry +
   pinout live-verify)
3. ~~Verify the PT8211 pinout~~ — **done** (PT8211-S.pdf in this
   directory): 6=LCH/8=RCH were swapped in the draft netlist (harmless
   — mono sum) and are now corrected. Dual U6 position: DIP-8 socket or
   SOP-8 land (U6B), populate exactly one. Both packages exist
   (PT8211 = DIP, PT8211-S = SO).
4. Footprint audit (2026-08-31): everything on the boards is standard
   0.1" through-hole (DIP sockets, Pico rows at the official 0.700"
   spacing, headers). J1 is now a real CUI SJ1-3523N TRS jack using the
   KiCad-maintained footprint (CUI datasheet-derived); output is true
   stereo per the PJRC PT8211 adapter topology.
   Radial caps on the 0.3" axial positions just need a bent lead.

## BOM (per assembled card)

| ref | part | note |
|-----|------|------|
| — | Raspberry Pi **Pico WH** | socketed; WH = headers + JST-SH debug |
| — | 2 × 1×20 female header, 0.1" | the Pico socket |
| U1, U2 | SN74LVC245AN (DIP-20) | 3.3 V supply, 5 V-tolerant inputs |
| U3, U4 | SN74HCT541N (DIP-20) | ID 0xA5 / STATUS 0x57 |
| U5 | SN74HCT138N (DIP-16) | read decode |
| U6 | PT8211-S (SOP-8) → U6B land, or DIP adapter in socket | I2S DAC — **verify pinout**; populate one position only |
| — | DIP sockets: 4 × 20-pin, 1 × 16-pin, 1 × 8-pin | everything socketed |
| C1–C6 | 0.1 µF ceramic | decoupling |
| C7, C8 | 10 µF electrolytic | bulk, +5V |
| C9, C12 | 47 µF electrolytic | L/R audio coupling (PJRC topology) |
| C11 | 47 µF electrolytic | VDDF bulk |
| C13 | 10 µF electrolytic | PWM-fallback coupling |
| R6 | 10 Ω | VDD filter |
| C10 | 100 nF | PWM filter |
| R4 | 1 kΩ | PWM filter |
| R5 | 10 kΩ | PWM into sum |
| J1 | CUI SJ1-3523N 3.5 mm TRS jack | stereo line out; KiCad-library footprint |
| J2 | 1×2 0.1" header | speaker mix-in |

Riser BOM: 2 × 1×15 (or one 2×15) 0.1" male header.

**Audio output options** (J1 is line-level, ~1 Vpp, from the DAC through
a coupling cap):
- Powered speakers / amplified PC desktop speakers / line-in: plug
  straight into the J1 pigtail jack — the intended path.
- A bare 8 Ω speaker (PC-case beeper style) directly on J1: will be
  nearly inaudible — line-out cannot drive 8 Ω. Use a $2 amp module
  (PAM8302/LM386) between J1 and the speaker, or wait for v2 which
  should add an on-board amp stage.
- J2 SPKR MIX feeds the WSG into the Advantage's own internal speaker
  amplifier (tap point per the conversion notes) — the self-contained
  option: game sound from the machine's own speaker.

Approx totals: boards + shipping ≈ $60–90; parts ≈ $20/card.

## After the boards arrive

1. Riser: continuity map against the pinout table, then in-machine.
2. Card: populate sockets only, power from bench +5 first (check 3V3
   rail at Pico), then chips, then in-machine: board-ID probe from the
   NSPacMan WSG branch should find 0xA5 and STATUS 0x57 with no
   firmware at all — the wired logic answers by itself.
3. Firmware bring-up: port `run_wsg.c`'s model; `wsgtest.nsi` is the
   acceptance test — the machine should sound exactly like NorthMac.
