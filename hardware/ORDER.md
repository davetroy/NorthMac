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
3. **Verify PT8211 pinout against the datasheet** before populating U6
   (silk-flagged; the DAC is socketed, so worst case is a re-seat)

## BOM (per assembled card)

| ref | part | note |
|-----|------|------|
| — | Raspberry Pi **Pico WH** | socketed; WH = headers + JST-SH debug |
| — | 2 × 1×20 female header, 0.1" | the Pico socket |
| U1, U2 | SN74LVC245AN (DIP-20) | 3.3 V supply, 5 V-tolerant inputs |
| U3, U4 | SN74HCT541N (DIP-20) | ID 0xA5 / STATUS 0x57 |
| U5 | SN74HCT138N (DIP-16) | read decode |
| U6 | PT8211 (DIP) | I2S DAC — **verify pinout** |
| — | DIP sockets: 4 × 20-pin, 1 × 16-pin, 1 × 8-pin | everything socketed |
| C1–C6 | 0.1 µF ceramic | decoupling |
| C7, C8 | 10 µF electrolytic | bulk, +5V |
| C9 | 10 µF NP electrolytic | audio coupling |
| C10 | 100 nF | PWM filter |
| R1, R2, R4 | 1 kΩ | audio sum / PWM |
| R5 | 10 kΩ | PWM into sum |
| J1 | 3.5 mm TRS jack, PCB mount | line out |
| J2 | 1×2 0.1" header | speaker mix-in |

Riser BOM: 2 × 1×15 (or one 2×15) 0.1" male header.

Approx totals: boards + shipping ≈ $60–90; parts ≈ $20/card.

## After the boards arrive

1. Riser: continuity map against the pinout table, then in-machine.
2. Card: populate sockets only, power from bench +5 first (check 3V3
   rail at Pico), then chips, then in-machine: board-ID probe from the
   NSPacMan WSG branch should find 0xA5 and STATUS 0x57 with no
   firmware at all — the wired logic answers by itself.
3. Firmware bring-up: port `run_wsg.c`'s model; `wsgtest.nsi` is the
   acceptance test — the machine should sound exactly like NorthMac.
