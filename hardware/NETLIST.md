# NS-WSG v1 — Complete Netlist

*Pin-level circuit definition. This is the source of truth for the KiCad
schematic; the ratsnest page in `nswsg_layers_1to1.pdf` visualizes it.
Routing happens in KiCad against this document.*

## Power

| net | sources | loads |
|-----|---------|-------|
| +5V | slot pins 4, 27 | U3.20, U4.20, U5.16, Pico.39 (VSYS), pull-up RN1 |
| +3V3 | Pico.36 (3V3 OUT) | U1.20, U2.20, U6 VCC (PT8211 runs at 3.3 V — its VIH at 5 V supply would exceed the Pico's 3.3 V outputs) |
| GND | slot pins 1, 12, 21, 30 | all IC grounds, Pico.3/8/13/18/23/28/33/38, J1-J3 |

Decoupling: 0.1 µF at every VCC pin, 10 µF bulk at the slot +5V entry and
at Pico VSYS.

## U1 — 74LVC245 (data bus in), VCC = 3.3 V, inputs 5 V-tolerant

| pin | net | | pin | net |
|-----|-----|-|-----|-----|
| 1 DIR | +3V3 (A→B) | | 20 VCC | +3V3 |
| 2 A0 | IO0 (slot 25) | | 18 B0 | GP0 |
| 3 A1 | IO1 (slot 24) | | 17 B1 | GP1 |
| 4 A2 | IO2 (slot 19) | | 16 B2 | GP2 |
| 5 A3 | IO3 (slot 17) | | 15 B3 | GP3 |
| 6 A4 | IO4 (slot 20) | | 14 B4 | GP4 |
| 7 A5 | IO5 (slot 22) | | 13 B5 | GP5 |
| 8 A6 | IO6 (slot 23) | | 12 B6 | GP6 |
| 9 A7 | IO7 (slot 28) | | 11 B7 | GP7 |
| 10 GND | GND | | 19 /OE | GND (always enabled — inputs only) |

## U2 — 74LVC245 (address + strobes in), VCC = 3.3 V

| pin | net | | pin | net |
|-----|-----|-|-----|-----|
| 2 A0 | IOA0 (slot 14) | | 18 B0 | GP8 |
| 3 A1 | IOA1 (slot 11) | | 17 B1 | GP9 |
| 4 A2 | IOA2 (slot 9) | | 16 B2 | GP10 |
| 5 A3 | IOA3 (slot 10) | | 15 B3 | GP11 |
| 6 A4 | /SELECT (slot 29) | | 14 B4 | GP12 |
| 7 A5 | /BWR (slot 16) | | 13 B5 | GP13 |
| 8 A6 | /BIO RES (slot 18) | | 12 B6 | GP14 |
| 9 A7 | 8MHZ (slot 15) | | 11 B7 | GP15 |
| 1 DIR +3V3, 19 /OE GND, 10 GND, 20 VCC +3V3 | | | | |

## U3 — 74HCT541 (board ID 0xA5), VCC = 5 V

Wired-OR ID per the SIO/PIO pattern: during /ID REQ, ground the ZERO bits
of 0xA5 (bits 1, 3, 4, 6); pull-ups on the motherboard supply the ones.

| pin | net |
|-----|-----|
| 1 /G1, 19 /G2 | /ID REQ (slot 3) |
| A inputs (4 used) | GND |
| Y → IO1 (slot 24), IO3 (slot 17), IO4 (slot 20), IO6 (slot 23) | |
| unused A/Y | A→GND, Y n/c |

## U4 — 74HCT541 (STATUS 0x57), VCC = 5 V

Answers reads of base+3. **Four-bit decode via the two enables**:
/G1 = /RD3 from U5 (covers /SELECT+/BRD+IOA2:0 = 3), **/G2 = IOA3** —
enabled only when IOA3 = 0, so no inverter is needed and there is no
alias at base+0xB.

| pin | net |
|-----|-----|
| 1 /G1 | /RD3 (U5.12) |
| 19 /G2 | IOA3 (slot 10) |
| A0-A7 | strapped to 0x57: A0,A1,A2,A4,A6 → +5V; A3,A5,A7 → GND |
| Y0-Y7 | IO0-IO7 (slot 25,24,19,17,20,22,23,28) |

## U5 — 74HCT138 (read decode), VCC = 5 V

| pin | net |
|-----|-----|
| 1 A | IOA0 (slot 14) |
| 2 B | IOA1 (slot 11) |
| 3 C | IOA2 (slot 9) |
| 4 /E1 | /SELECT (slot 29) |
| 5 /E2 | /BRD (slot 13) |
| 6 E3 | +5V |
| 12 Y3 | /RD3 → U4./G1 |
| others | n/c |

## Pico W (socketed) — GPIO map

The module is a **Raspberry Pi Pico W** on female headers (WH variant =
pre-soldered pins + JST-SH debug connector). WiFi enables OTA firmware
updates and a live synth-state web view; the antenna end (opposite USB,
pins ~19-22) has a board keep-out: no vias or copper pour beneath it,
only those pins' own escapes. Firmware: WiFi/lwIP on core 0, WSG synth
+ PIO bus capture on core 1.

| GPIO | net | role |
|------|-----|------|
| GP0-7 | data IO0-7 (via U1) | PIO bus capture |
| GP8-11 | IOA0-3 (via U2) | PIO bus capture |
| GP12 | /SELECT | PIO trigger qualify |
| GP13 | /BWR | PIO write strobe |
| GP14 | /BIO RES | firmware reset-in (disable sound, zero accs) |
| GP15 | 8MHZ | optional tick reference (firmware may free-run) |
| GP18 | BCK → U6 | I2S bit clock |
| GP19 | WS → U6 | I2S word select |
| GP20 | DIN → U6 | I2S data |
| GP21 | PWM audio (fallback path) → R/C → J2 | |
| (LED) | on the wireless chip on Pico W — firmware-only | |

Debug: the Pico WH's own JST-SH SWD connector and USB (BOOTSEL / OTA);
no board-level debug header.

The Pico **never drives the slot bus** — U1/U2 are inputs only; the two
read responses come from U3/U4.

## Audio

- U6 PT8211, pinout **verified against the datasheet** (PT8211-S.pdf,
  in this directory): 1 BCK, 2 WS, 3 DIN, 4 GND, 5 VDD, 6 LCH, 7 NC,
  8 RCH. Dual position on the board: DIP-8 socket or SOP-8 land (U6B).
- **Stereo, PJRC PT8211-adapter topology** (protosupplies.com Teensy
  adapter / PJRC kit): LCH → C9 47 µF → J1 tip; RCH → C12 47 µF → J1
  ring. J1 = CUI SJ1-3523N 3.5 mm TRS (footprint from the KiCad
  library), barrel overhanging the right board edge.
- VDD filter per the datasheet app circuit: +3V3 → R6 10 Ω → VDDF,
  with C11 47 µF + C6 100 nF at the pin.
- J2 speaker mix-in: left channel via R5 10 kΩ. PWM fallback: GP21 →
  R4 1 kΩ → C10 100 nF LPF → C13 10 µF → left channel.
- Supply: datasheet nominal is 5 V; we run it at **3.3 V**, the
  established Pico-ecosystem practice (Pico Audio Pack does the same),
  which keeps the Pico's 3.3 V logic within input thresholds.
- **Firmware note: the PT8211 takes "Japanese"/LSB-justified 16-bit
  serial data, NOT standard I2S** — the PIO program must use the
  right-justified format (or the DAC plays garbage at the wrong level).

## Bus loading note

One LVC245 input + one HCT541 tri-stated output + one HCT138 input per
line — comparable to the stock SIO's loading (LS243 + LS175 inputs).
No pull-ups added on the card; the motherboard owns the bus.
