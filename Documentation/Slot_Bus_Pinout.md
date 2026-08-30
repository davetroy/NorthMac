# Advantage I/O Slot Bus — Electrical Pinout

*Extracted 2026-08-30 from the SIO PCB schematic (dwg 00111, left half =
advtech.pdf p386) and PIO PCB schematic (dwg 00146, p388-389), cross-checked
against manual §3.9. Basis for the NS-WSG card design. Pins marked (?) need
confirmation by buzz-out on a real card — see "To verify" below.*

The slot connector (J1/P1 on the cards) is a **30-contact card-edge
connector**. All signals are buffered by the motherboard ("B"/"IO" prefixes =
buffered I/O bus); the motherboard does all port decoding and hands each slot
a decoded /SELECT for its own 16-port window.

## Pin table

| pin | signal   | notes |
|-----|----------|-------|
| 1   | GND      | |
| 3   | /ID REQ  | asserted while the CPU reads this slot's board-ID port (0x70+n) |
| 4   | +5V      | |
| 5   | +12V     | (SIO uses it for RS-232 drivers) |
| 7   | /IO INT  | shared interrupt line, open-collector (cards use 7437/LS03); STAT1 bit 1 |
| 9   | IOA2     | |
| 10  | IOA3     | (SIO decodes it; PIO ignores it — 16-port window confirmed) |
| 11  | IOA1     | |
| 12  | GND      | |
| 13  | /BRD     | buffered I/O read strobe |
| 14  | IOA0     | |
| 15  | 8 MHz    | bus clock ("IO 8 MHZ" on the SIO sheet) |
| 16  | /BWR     | buffered I/O write strobe |
| 17  | IO3      | |
| 18  | /BIO RES | buffered I/O reset — IOCTL (0xF8) bit 4, low = reset (§3.9.2) |
| 19  | IO2      | |
| 20  | IO4      | |
| 21  | GND      | |
| 22  | IO5      | |
| 23  | IO6      | |
| 24  | IO1      | |
| 25  | IO0      | |
| 26  | −12V     | |
| 27  | +5V      | |
| 28  | IO7 (?)  | SIO reads as 28; the PIO scan could be read as 26 — buzz out |
| 29  | /SELECT  | this slot's decoded select for its 16-port window |
| 30  | GND      | |

Pins 2, 6, 8 do not appear on either card schematic — likely unused or
additional grounds; confirm by buzz-out.

## Mechanisms (from the card schematics)

- **Port cycle**: the card qualifies /SELECT with /BRD or /BWR and decodes
  IOA0-3 (PIO: LS138 on IOA0-2; SIO: LS13B plus IOA3 gating). Data bus IO0-7
  is bidirectional; cards drive it with LS243/LS367 tri-states during reads
  only.
- **Board ID is wired-OR, not a register**: the ID ports idle at 0xFF
  (pull-ups). During /ID REQ, the card grounds the *zero* bits of its
  signature through 74367 tri-states — the PIO pulls IO2 and IO5 low
  (0xDB), the SIO pulls IO3 (0xF7). **The NS-WSG (0xA5 = 1010 0101) pulls
  IO1, IO3, IO4, IO6 low during /ID REQ** — four buffer sections enabled by
  /ID REQ, no MCU involvement.
- **Reset**: /BIO RES low resets the card (drop IOCTL bit 4 then raise it).
  For NS-WSG: disable sound, zero accumulators.
- **Interrupt**: open-collector pull on /IO INT (we don't need it for v1).
- **Write timing** (PIO sheet timing diagram): strobes on the order of
  250 ns edges with ~1.2 µs cycle windows — comfortable for RP2040 PIO
  capture, and the reference cards latch with plain LS373s.
- **Clock**: 8 MHz on pin 15. For the WSG tick: ÷ 84 → 95.24 kHz (0.8%
  below the nominal 96 kHz, inaudible), or resample in firmware.

## NS-WSG card implications

The spec was designed so all dynamic registers are write-only; the only
reads are constants. On this bus that means:

- **Writes**: /SELECT + /BWR + IOA0-3 + IO0-7 → level-shift (74LVC245)
  into RP2040 PIO. No response timing required of the MCU.
- **STATUS read (base+3)**: /SELECT + /BRD + IOA=3 → enable a 74HCT541
  strapped to 0x57. Pure logic.
- **ID read**: /ID REQ → enable a 367/541 pulling IO1/IO3/IO4/IO6 low.
  Pure logic.
- The RP2040 never drives the bus. One 74LVC245 (inputs), two HCT541s
  (constants), one HCT138-ish decode, done.

## To verify (buzz-out session on the real PIO card)

1. IO7 on pin 28 vs 26 (and −12V on the other).
2. /SELECT on 29; pins 2, 6, 8 unused?
3. Physical: contact pitch, finger dimensions, card outline, bracket —
   measure the PIO card with calipers; the connector on the motherboard
   is the mating reference.
4. Confirm /ID REQ polarity and that it is per-slot (schematics imply it).
