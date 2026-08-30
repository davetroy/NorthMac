# NS-WSG Sound Card — Design Record

*2026-08-30, branch `experimental/wsg`. Everything learned so far toward a
manufacturable Advantage sound card. Companion documents:
[NSWSG.md](NSWSG.md) (the register spec) and
[Slot_Bus_Pinout.md](Slot_Bus_Pinout.md) (the slot bus).*

## Status

| piece | state |
|---|---|
| NS-WSG v1 register spec | written; three implementations agree |
| Emulation (WSGDevice.swift, slot 3) | working — audible in NorthMac |
| Independent C model (wsgtest/run_wsg.c) | working — renders WAV, FFT-verified |
| Bare-metal demo/acceptance test (wsgtest.asm) | working — slot probe, waveform upload, Pac-Man-style effects reel |
| Slot bus pinout | extracted from SIO/PIO schematics; 4 items await buzz-out |
| Physical measurements (pitch, outline) | pending caliper session on the real PIO card |
| KiCad design | not started (unblocked once measurements land) |

## Key findings

1. **No WSG chip exists to buy.** Original Pac-Man's sound is TTL + a
   256×4 waveform PROM on the main board — never a purchasable LSI. Namco's
   later customs (15XX, CUS30) exist only on donor boards. Conclusion: we
   implement our own spec (NS-WSG v1) — which also frees us from Namco's
   PROM data (we upload our own waveforms over the bus).

2. **The spec deliberately makes all dynamic registers write-only.** The
   only reads are constants (board ID 0xA5, STATUS 0x57). Consequence: the
   MCU never has to win a Z80 read-cycle race — the hardest timing problem
   in peripheral design simply doesn't exist on this card.

3. **Board ID is wired-OR** (from the SIO/PIO schematics): ID ports idle
   0xFF; during /ID REQ the card grounds its signature's zero bits through
   tri-states (PIO: IO2+IO5 → 0xDB; SIO: IO3 → 0xF7). NS-WSG grounds
   IO1/IO3/IO4/IO6 → 0xA5. Pure logic, no MCU.

4. **The slot hands us everything**: decoded per-slot /SELECT (16-port
   window, IOA0-3), /BRD //BWR strobes, /BIO RES (= IOCTL bit 4, §3.9.2),
   an 8 MHz clock on pin 15 (÷84 → 95.24 kHz WSG tick, 0.8% flat —
   inaudible), +5/±12V. Write strobes are ~1.2 µs windows with ~250 ns
   edges (PIO sheet timing diagram) — easy PIO-capture territory.

5. **The bus is 5V TTL.** Whatever runs the synth must sit behind level
   shifting (74LVC245 inputs are 5V-tolerant; 3.3V outputs drive TTL
   thresholds fine, but this card's MCU never drives the bus anyway).

## Chosen architecture (v1 card)

**RP2040 as the synthesizer, jellybean logic as the bus face.**

```
edge fingers ── 74LVC245 ──► RP2040 PIO (watch /SELECT+/BWR, latch IOA0-3 + IO0-7)
     │                          │ firmware: NS-WSG v1 (port of run_wsg.c model)
     │                          └─► PWM + RC filter (or PT8211 I2S DAC) ─► jack
     │                                                        └─► mix-in header (speaker amp)
     ├── /ID REQ ──► 74HCT541 grounding IO1/IO3/IO4/IO6      (ID = 0xA5)
     ├── /SELECT+/BRD+IOA=3 ──► 74HCT541 strapped to 0x57    (STATUS)
     └── /BIO RES ──► RP2040 reset-in (disable sound, zero accumulators)
```

- RP2040 + W25Q16 flash + 12 MHz crystal + 3.3V LDO (copy the Pico
  reference design)
- Alternatives considered: iCE40 FPGA (closer to the original spirit, more
  toolchain, no manufacturing advantage); 5V CPLD alone (rejected — no RAM
  for waveforms); TTL rebuild of the Pac-Man circuit (the romantic stretch
  goal, ~15-20 chips + PROM + ladder DAC, kept in the plans doc)
- Also rejected for v1: driving the bus for rich readback — not worth
  losing finding #2.

## Manufacturing notes (PCBWay or equivalent)

- 2-layer is plenty; **gold fingers + beveled edge** option for the
  connector (small upcharge; specify chamfer after measurements).
- Assembly service can place everything; all parts stocked (RP2040,
  LVC/HCT logic, passives). Ballpark: $50-100/board run + $10-15 parts.
- **First spin should be the breakout riser**: a dumb card that brings all
  30 fingers out to headers. ~$10, validates the pinout + measurements
  against the live bus with a Pico on a breadboard before the real card,
  and remains a bus-probing tool forever.

## Verification strategy

Three implementations of one spec cross-check each other:
Swift (NorthMac) ⇄ C (run_wsg.c) ⇄ hardware (RP2040 firmware, a port of
the C model). `wsgtest.asm` is the acceptance test — the same boot disk
must sound identical on all three. The harness also renders WAV for FFT
verification (drone/arpeggio/siren all confirmed on-pitch) and traps
SP leaks / runaway PC.

## Open items

1. **Buzz-out** (user, at the machine): IO7 pin 28 vs 26; pins 2/6/8
   unused?; /ID REQ polarity/per-slot; physical measurements (finger
   pitch, count per side, edge length, card outline, bracket).
2. KiCad: edge-connector footprint from measurements → riser → full card.
3. RP2040 firmware: port run_wsg.c's model; PIO program for bus capture.
4. Software: NSPacMan driver layer (probe 0xA5, three voices, speaker
   fallback) — planned next after the card exists in emulation only.

## Lessons banked along the way

- wsgtest found the slot-base formula bug (base = idIndex<<4, NOT
  (5-idx)<<4) — the probe-don't-hardcode rule already paid off.
- A stack leak in the siren sweep sent execution into video RAM (0xFF
  bar bytes = RST 38 storm). The harness now trips on SP descent and
  reports final PC/SP — keep that net for firmware bring-up too.
