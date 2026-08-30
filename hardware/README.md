# NS-WSG Card Hardware

## NSAdvantage_Slot_Edge_30.kicad_mod

KiCad footprint for the Advantage I/O slot card edge, generated from the
measured geometry (see `../Documentation/Slot_Bus_Pinout.md`):

- 30 contacts: 15 positions/side, **0.125" (3.175 mm) pitch**, span 1.75"
  between first and last centers
- **F.Cu (component side) = even pins 2..30; B.Cu (solder side) = odd
  pins 1..29**; position k carries pins 2k−1/2k; "1/2" and "29/30"
  silkscreen labels mark the ends
- finger 2.2 mm wide × 8.4 mm gold depth; no polarization key (the
  machine's card guides enforce orientation)
- fab notes: gold fingers + beveled edge option at the board house;
  pads are mask-defined copper, no paste

**Before fab**: lay a printout at 1:1 over a real SIO card and check
finger alignment and left/right orientation; then the breakout riser
(below) verifies the electrical map against the live bus.

## nswsg_layers_1to1.pdf / make_board_layers.py

Placement-level design of the full v1 card as an 8-page, true-1:1 PDF:
top/bottom assembly renders plus F.Cu / F.Mask / F.SilkS / B.Cu /
B.Mask / B.SilkS fab-style plots. Back-side pages are x-mirrored for
direct overlay. The outline includes the **connector tab** (edge
relieved around a ~0.33" x 2.0" chamfered tongue, per the real SIO) —
this outline is what goes on Edge.Cuts in the routed board.

## riser.kicad_pcb / riser_fab.zip — THE FIRST FAB-READY BOARD

`make_riser.py` generates a real KiCad board: the measured slot tab
fanned out to a 2x15 0.1" header, every pin silkscreen-labeled, fully
routed (evens on front with a half-pitch jog through the odd column,
odds direct on back). **KiCad 10 DRC: 0 violations, 0 unconnected.**
`riser_fab.zip` = Gerbers + drill, ready for PCBWay/JLCPCB. Order
options: 1.6 mm, HASL or ENIG, and select **gold fingers + 20-degree
bevel** on the connector edge. kicad-cli lives at
`~/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli`.

## Plan

1. **Breakout riser** — this footprint + 2×15 pin header + silkscreened
   pin names. Validates geometry and pinout on a real machine for ~$10.
2. **NS-WSG card** — riser front-end + RP2040 (Pico reference design) +
   74LVC245 bus input + two strapped 74HCT541s (board ID 0xA5 via
   /ID REQ, STATUS 0x57) + PWM/RC or PT8211 audio out + speaker mix-in
   header. Spec: `../Documentation/NSWSG.md`; design record:
   `../Documentation/NSWSG_Card_Design.md`.
