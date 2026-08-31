#!/usr/bin/env python3
# Generates card.kicad_pcb — the full NS-WSG v1 board, unrouted:
# all footprints placed, every pad carrying its net per NETLIST.md.
# Routing: export Specctra DSN (pcbnew python), route with freerouting,
# import SES, then DRC. Geometry per Slot_Bus_Pinout.md (y DOWN).
IN = 25.4
CW, CH = 5.30, 3.15
TD, FW, PITCH, CHAM = 0.331, 0.0866, 0.125, 0.05
def fy(k): return 0.45 + (15 - k) * PITCH
TAB_T = fy(15) - FW/2 - 0.08
TAB_B = fy(1) + FW/2 + 0.08

NETS = ["GND","+5V","+3V3",
"IO0","IO1","IO2","IO3","IO4","IO5","IO6","IO7",
"IOA0","IOA1","IOA2","IOA3","SEL","BWR","BRD","IDREQ","BIORES","MHZ8",
"GP0","GP1","GP2","GP3","GP4","GP5","GP6","GP7","GP8","GP9","GP10",
"GP11","GP12","GP13","GP14","GP15","RD3","BCK","WS","DIN","PWM",
"AOL","AOR","ASUM","AOUT","PWMF"]
NID = {n: i+1 for i, n in enumerate(NETS)}

def mm(v): return round(v * IN, 4)
pads, texts, edges = [], [], []
_pn = [0]
def pad(num, kind, x, y, sx, sy, layers, drill=None, shape="circle", net=None):
    # every pad lives in one footprint: names must be globally unique
    _pn[0] += 1
    d = f' (drill {drill})' if drill else ''
    lay = ' '.join(f'"{l}"' for l in layers)
    n = f' (net {NID[net]} "{net}")' if net else ''
    pads.append(f'    (pad "{_pn[0]}" {kind} {shape} (at {mm(x)} {mm(y)}) (size {mm(sx)} {mm(sy)}){d} (layers {lay}){n})')
def txt(x, y, t, size=0.9, layer="F.SilkS"):
    texts.append(f'  (gr_text "{t}" (at {mm(x)} {mm(y)}) (layer "{layer}") (effects (font (size {size} {size}) (thickness 0.15))))')

# ---- slot fingers (only the pins we use, like the SIO) ----
slot = {1:"GND",3:"IDREQ",4:"+5V",9:"IOA2",10:"IOA3",11:"IOA1",12:"GND",
13:"BRD",14:"IOA0",15:"MHZ8",16:"BWR",17:"IO3",18:"BIORES",19:"IO2",
20:"IO4",21:"GND",22:"IO5",23:"IO6",24:"IO1",25:"IO0",27:"+5V",
28:"IO7",29:"SEL",30:"GND"}
for k in range(1, 16):
    for pin, side in ((2*k, "F"), (2*k-1, "B")):
        if pin in slot:
            pad(pin, "smd", -TD/2 + 0.01, fy(k), TD - 0.04, FW,
                [f"{side}.Cu", f"{side}.Mask"], shape="rect", net=slot[pin])

# ---- DIPs (vertical, pin 1 top-left, 1..n/2 down left, n/2+1..n up right) ----
def dip(x, y, n, ref, nets):
    rows = n // 2
    for i in range(rows):
        pad(i+1, "thru_hole", x, y + i*0.1, 0.062, 0.062, ["*.Cu","*.Mask"],
            drill=0.8, net=nets.get(i+1))
        pad(n-i, "thru_hole", x+0.3, y + i*0.1, 0.062, 0.062, ["*.Cu","*.Mask"],
            drill=0.8, net=nets.get(n-i))
    texts.append(f'  (gr_rect (start {mm(x+0.04)} {mm(y-0.06)}) (end {mm(x+0.26)} {mm(y+(rows-1)*0.1+0.06)}) (layer "F.SilkS") (width 0.15) (fill none))')
    txt(x - 0.02, y - 0.14, ref, 0.8)

IO = ["IO0","IO1","IO2","IO3","IO4","IO5","IO6","IO7"]
dip(0.65, 0.20, 20, "U1 LVC245", {1:"+3V3",10:"GND",19:"GND",20:"+3V3",
    **{i+2: IO[i] for i in range(8)}, **{18-i: f"GP{i}" for i in range(8)}})
ADR = ["IOA0","IOA1","IOA2","IOA3","SEL","BWR","BIORES","MHZ8"]
dip(0.65, 1.30, 20, "U2 LVC245", {1:"+3V3",10:"GND",19:"GND",20:"+3V3",
    **{i+2: ADR[i] for i in range(8)}, **{18-i: f"GP{i+8}" for i in range(8)}})
dip(1.25, 0.20, 20, "U3 ID 0xA5", {1:"IDREQ",19:"IDREQ",10:"GND",20:"+5V",
    2:"GND",3:"GND",4:"GND",5:"GND",6:"GND",7:"GND",8:"GND",9:"GND",
    17:"IO1",15:"IO3",14:"IO4",12:"IO6"})
dip(1.25, 1.30, 20, "U4 ST 0x57", {1:"RD3",19:"IOA3",10:"GND",20:"+5V",
    2:"+5V",3:"+5V",4:"+5V",5:"GND",6:"+5V",7:"GND",8:"+5V",9:"GND",
    **{18-i: IO[i] for i in range(8)}})
dip(1.25, 2.35, 16, "U5 HCT138", {1:"IOA0",2:"IOA1",3:"IOA2",4:"SEL",
    5:"BRD",6:"+5V",8:"GND",12:"RD3",16:"+5V"})
dip(4.05, 0.30, 8, "U6 PT8211 (VERIFY PINOUT)", {1:"BCK",2:"WS",3:"DIN",
    4:"GND",5:"+3V3",6:"AOR",8:"AOL"})

# ---- Pico module: bottom row pins 1-20 L2R at y=1.93, top row 21-40 R2L at y=1.23
pico = {1:"GP0",2:"GP1",3:"GND",4:"GP2",5:"GP3",6:"GP4",7:"GP5",8:"GND",
9:"GP6",10:"GP7",11:"GP8",12:"GP9",13:"GND",14:"GP10",15:"GP11",16:"GP12",
17:"GP13",18:"GND",19:"GP14",20:"GP15",23:"GND",24:"BCK",25:"WS",26:"DIN",
27:"PWM",28:"GND",33:"GND",36:"+3V3",38:"GND",39:"+5V"}
for i in range(20):
    pad(i+1, "thru_hole", 1.95 + i*0.1, 1.93, 0.062, 0.062, ["*.Cu","*.Mask"],
        drill=0.8, net=pico.get(i+1))
    pn = 40 - i
    pad(pn, "thru_hole", 1.95 + i*0.1, 1.23, 0.062, 0.062, ["*.Cu","*.Mask"],
        drill=0.8, net=pico.get(pn))
texts.append(f'  (gr_rect (start {mm(1.88)} {mm(1.17)}) (end {mm(3.92)} {mm(1.99)}) (layer "F.SilkS") (width 0.15) (fill none))')
txt(2.35, 1.58, "RASPBERRY PI PICO W (socketed)", 1.0)
txt(3.55, 1.10, "ANTENNA", 0.8)
texts.append(f'  (zone (net 0) (net_name "") (layers "F.Cu" "B.Cu") (name "antenna-keepout") (hatch edge 0.508)'
             f' (connect_pads (clearance 0))'
             f' (min_thickness 0.25)'
             f' (keepout (tracks allowed) (vias not_allowed) (pads allowed) (copperpour not_allowed) (footprints allowed))'
             f' (fill (thermal_gap 0.5) (thermal_bridge_width 0.5))'
             f' (polygon (pts (xy {mm(3.62)} {mm(1.14)}) (xy {mm(4.02)} {mm(1.14)}) (xy {mm(4.02)} {mm(2.02)}) (xy {mm(3.62)} {mm(2.02)}))))')

# ---- audio passives + connectors ----
def r2(ref, x, y, n1, n2, dy=0.3):
    pad("1", "thru_hole", x, y, 0.062, 0.062, ["*.Cu","*.Mask"], drill=0.8, net=n1)
    pad("2", "thru_hole", x, y+dy, 0.062, 0.062, ["*.Cu","*.Mask"], drill=0.8, net=n2)
    txt(x + 0.06, y + dy/2, ref, 0.8)
r2("R1 1K", 4.30, 0.75, "AOL", "ASUM")
r2("R2 1K", 4.45, 0.75, "AOR", "ASUM")
r2("C9 10u", 4.62, 0.75, "ASUM", "AOUT")
r2("R4 1K", 4.20, 1.60, "PWM", "PWMF")
r2("C10 100n", 4.36, 1.60, "PWMF", "GND")
r2("R5 10K", 4.52, 1.60, "PWMF", "ASUM")
# J1 audio jack (tip/ring/sleeve), J2 mix-in, J3 SWD
pad("1", "thru_hole", 4.75, 0.30, 0.078, 0.078, ["*.Cu","*.Mask"], drill=1.1, net="AOUT")
pad("2", "thru_hole", 4.75, 0.45, 0.078, 0.078, ["*.Cu","*.Mask"], drill=1.1, net="AOUT")
pad("3", "thru_hole", 4.75, 0.60, 0.078, 0.078, ["*.Cu","*.Mask"], drill=1.1, net="GND")
txt(4.55, 0.18, "J1 AUDIO", 0.8)
pad("1", "thru_hole", 4.95, 1.35, 0.067, 0.067, ["*.Cu","*.Mask"], drill=1.0, net="AOUT")
pad("2", "thru_hole", 4.95, 1.45, 0.067, 0.067, ["*.Cu","*.Mask"], drill=1.0, net="GND")
txt(4.60, 1.28, "J2 SPKR MIX", 0.8)
# decoupling: (x, y, vcc)
for i,(cx, cy, v) in enumerate([(0.55,0.10,"+3V3"),(0.55,1.20,"+3V3"),
    (1.15,0.10,"+5V"),(1.15,1.20,"+5V"),(1.15,2.25,"+5V"),
    (3.95,0.30,"+3V3"),(2.30,2.20,"+5V"),(3.30,2.20,"+5V")]):
    r2(f"C{i+1}", cx, cy, v, "GND", dy=0.1)

# ---- mounting holes, outline, silk ----
for hx, hy in [(0.25,0.25),(0.25,CH-0.25),(CW-0.25,0.25),(CW-0.25,CH-0.25)]:
    pad("", "np_thru_hole", hx, hy, 0.150, 0.150, ["*.Cu","*.Mask"], drill=3.2)
pts = [(0,0),(CW,0),(CW,CH),(0,CH),(0,TAB_B),(-TD+CHAM,TAB_B),(-TD,TAB_B-CHAM),
       (-TD,TAB_T+CHAM),(-TD+CHAM,TAB_T),(0,TAB_T),(0,0)]
for i in range(len(pts)-1):
    (x1,y1),(x2,y2) = pts[i], pts[i+1]
    edges.append(f'  (gr_line (start {mm(x1)} {mm(y1)}) (end {mm(x2)} {mm(y2)}) (layer "Edge.Cuts") (width 0.1))')
txt(2.30, 0.10, "NS-WSG v1 - NorthStar Advantage wavetable sound card", 1.0)
txt(2.30, 0.24, "board ID 0xA5 - spec NSWSG.md", 0.8)
txt(2.00, 3.04, "\u00a9 2026 David Troy, in memory of Stephen Troy.", 0.9)

nets_s = "\n".join(f'  (net {NID[n]} "{n}")' for n in NETS)
netclass_members = "\n".join(f'    (add_net "{n}")' for n in NETS)
pcb = f'''(kicad_pcb (version 20221018) (generator nswsg)
  (general (thickness 1.6))
  (paper "A4")
  (layers
    (0 "F.Cu" signal)
    (31 "B.Cu" signal)
    (36 "B.SilkS" user)
    (37 "F.SilkS" user)
    (38 "B.Mask" user)
    (39 "F.Mask" user)
    (44 "Edge.Cuts" user)
  )
  (setup (pad_to_mask_clearance 0.05))
  (net 0 "")
{nets_s}
  (net_class "Default" "board nets"
    (clearance 0.2)
    (trace_width 0.25)
    (via_dia 0.7)
    (via_drill 0.35)
{netclass_members}
  )
  (footprint "nswsg:all" (layer "F.Cu") (at 0 0)
    (attr through_hole)
{chr(10).join(pads)}
  )
{chr(10).join(edges)}
{chr(10).join(texts)}
)
'''
open('card.kicad_pcb','w').write(pcb)
print(f"wrote card.kicad_pcb: {len(pads)} pads, {len(NETS)} nets")
