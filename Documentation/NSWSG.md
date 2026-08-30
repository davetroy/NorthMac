# NS-WSG v1 — Namco-style Waveform Sound Generator for the NorthStar Advantage

*Register-level specification. The NorthMac emulation
(`NorthMac/Core/WSGDevice.swift`, slot 3) is the reference implementation;
future hardware (CPLD / RP2040 / TTL on a real Advantage slot card) must
implement this spec so software runs unchanged.*

## Model

Three voices of wavetable synthesis, after the original Pac-Man sound
circuit but generalized:

- each voice: **20-bit frequency accumulator**, **4-bit volume** (0-15),
  one of **8 waveforms** (Pac-Man gave only voice 0 the 20-bit accumulator;
  gate count is no longer a constraint, so all three get it)
- **waveform RAM**: 8 waveforms × 32 samples × 4 bits (256 nibbles). RAM,
  not PROM — software uploads its own waveforms at init
- accumulators tick at **96 kHz** (as Pac-Man: 3.072 MHz/32); each tick
  `acc = (acc + freq) & 0xFFFFF`; output sample = `wave[wsel][acc >> 15]`
- tone frequency = `freq × 96000 / 2^20` Hz ≈ 0.09155 Hz per LSB
  (A440 = 4806; middle C = 2858)
- mixing: nibbles centered at 7.5, scaled by volume/15, three voices summed

## Slot interface

A standard Advantage I/O card (manual §3.9): the motherboard decodes a
16-port window per slot; the card sees the low 4 address bits, its slot
select, RD/WR strobes, and the data bus.

- **Board ID: 0xA5** (returned on the slot's ID read, ports 0x70+n /
  0x78+n per Table 3-20). Must not collide with SIO 0xF7, PIO 0xDB,
  HDC 0xBF, empty 0xFF.
- **Reset**: IOCTL (0xF8) bit 4 low→high resets the card (§3.9.2):
  disable sound, zero accumulators (waveform RAM contents undefined).
- NorthMac places the card in **slot 3** (ports 0x30-0x3F). Software must
  not hard-code the slot: probe the six ID ports for 0xA5, derive the base
  (`base = idIndex << 4`, since ID index 0 = slot 6 at 0x00 … index 5 =
  slot 1 at 0x50), and confirm with the STATUS read.

## Register map (base + offset)

| off  | dir | name   | function |
|------|-----|--------|----------|
| 0x0  | W   | WTIDX  | waveform RAM index 0-255 (= waveform*32 + position) |
| 0x1  | W   | WTDAT  | write sample nibble (bits 3:0) to `[WTIDX]`, then WTIDX++ |
| 0x2  | W   | CTRL   | bit 0 = master enable; writing 0 silences and zeroes accumulators |
| 0x3  | R   | STATUS | returns 0x57 ('W') — presence/version check |
| 0x4+4v | W | FLO    | voice v frequency bits 7:0 |
| 0x5+4v | W | FMID   | voice v frequency bits 15:8 |
| 0x6+4v | W | FHI    | voice v frequency bits 19:16 (low nibble) |
| 0x7+4v | W | VW     | bits 3:0 volume, bits 6:4 waveform select |

Voices v = 0,1,2 at offsets 0x4-0x7, 0x8-0xB, 0xC-0xF. All writes take
effect immediately; there is no timing hazard (register writes are static
latch operations, as on the AY).

## Hardware notes (for the eventual card)

- Tick clock: divide the slot's 4 MHz by 42 → 95.24 kHz (0.8% flat,
  inaudible) or use a dedicated 3.072 MHz crystal /32 for exactness.
- The three accumulators can time-multiplex one adder at 3×96 kHz, exactly
  as the original TTL circuit did, or simply be three registers in a CPLD.
- DAC: 4-bit resistor ladder per the Pac-Man schematic, volume applied
  digitally (nibble × vol) or as a second ladder.
- Waveform storage is RAM (e.g. a 256×4 or byte-wide SRAM), loaded through
  WTIDX/WTDAT — no PROM burning, and no Namco data: software ships its own
  waveforms.

## Reference software

- `northstar/tools/wsgtest/` — bare-metal demo payload (uploads three
  waveforms, plays melody + drone + siren sweep) and `run_wsg.c`, a
  headless harness that models this spec and renders the demo to WAV.
- NSPacMan's driver layer (planned): probe for 0xA5, use the WSG when
  present, fall back to the 1-bit speaker.
