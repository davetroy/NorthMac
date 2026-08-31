#!/usr/bin/env python3
# Generates riser.kicad_pcb — the NS-WSG breakout riser: Advantage slot tab
# on the left, all 30 bus pins fanned out to a 2x15 0.1" header. Fully routed;
# verify with `kicad-cli pcb drc`. Geometry per ../Documentation/Slot_Bus_Pinout.md.
IN = 25.4
# ---- geometry (inches, y DOWN like KiCad) ----
BW, BH = 1.50, 2.50                  # body
TD = 0.331                            # tab depth
FW = 0.0866                           # finger width
PITCH = 0.125
F_TOP = 0.45                          # y of position 15 (pins 29/30) center
CHAM = 0.05
def fy(k): return F_TOP + (15 - k) * PITCH          # finger center y, k=1..15
TAB_T = fy(15) - FW/2 - 0.08
TAB_B = fy(1) + FW/2 + 0.08
HX_ODD, HX_EVEN = 0.90, 1.00
def hy(k): return 0.55 + (15 - k) * 0.1             # header row y

names = {1:"GND",2:"NC2",3:"IDREQ",4:"+5V",5:"+12V",6:"NC6",7:"IOINT",8:"NC8",
9:"IOA2",10:"IOA3",11:"IOA1",12:"GND",13:"BRD",14:"IOA0",15:"8MHZ",16:"BWR",
17:"IO3",18:"BIORES",19:"IO2",20:"IO4",21:"GND",22:"IO5",23:"IO6",24:"IO1",
25:"IO0",26:"-12V",27:"+5V",28:"IO7",29:"SEL",30:"GND"}

def mm(v): return round(v * IN, 4)
S = []
def seg(x1, y1, x2, y2, layer, net, w=0.35):
    S.append(f'  (segment (start {mm(x1)} {mm(y1)}) (end {mm(x2)} {mm(y2)}) (width {w}) (layer "{layer}") (net {net}))')

pads = []
def pad(num, kind, x, y, sx, sy, layers, drill=None, shape="rect", net=None):
    d = f' (drill {drill})' if drill else ''
    lay = ' '.join(f'"{l}"' for l in layers)
    n = f' (net {net} "P{net}")' if net else ''
    pads.append(f'    (pad "{num}" {kind} {shape} (at {mm(x)} {mm(y)}) (size {mm(sx)} {mm(sy)}){d} (layers {lay}){n})')

texts = []
def txt(x, y, t, layer="F.SilkS", size=0.9, just=""):
    j = f' (justify {just})' if just else ''
    texts.append(f'  (gr_text "{t}" (at {mm(x)} {mm(y)}) (layer "{layer}") (effects (font (size {size} {size}) (thickness 0.15)){j}))')

# ---- pads ----
for k in range(1, 16):
    even, odd = 2*k, 2*k-1
    pad(even, "smd", -TD/2 + 0.01, fy(k), TD - 0.04, FW, ["F.Cu", "F.Mask"], net=even)
    pad(odd,  "smd", -TD/2 + 0.01, fy(k), TD - 0.04, FW, ["B.Cu", "B.Mask"], net=odd)
    pad(even, "thru_hole", HX_EVEN, hy(k), 0.067, 0.067, ["*.Cu", "*.Mask"], drill=1.0, shape="circle", net=even)
    pad(odd,  "thru_hole", HX_ODD,  hy(k), 0.067, 0.067, ["*.Cu", "*.Mask"], drill=1.0, shape="circle", net=odd)
    txt(HX_EVEN + 0.11, hy(k) + 0.015, f"{even} {names[even]}", size=0.7)
    txt(HX_ODD - 0.09, hy(k) + 0.015, f"{odd} {names[odd]}", size=0.7, just="right")

# ---- tracks ----
for k in range(1, 16):
    even, odd = 2*k, 2*k-1
    yf, yh = fy(k), hy(k)
    # even: front, jog half-pitch to pass between odd-column holes
    yj = yh + 0.05
    seg(-0.02, yf, 0.40, yf, "F.Cu", even)
    seg(0.40, yf, 0.72, yj, "F.Cu", even)
    seg(0.72, yj, 0.945, yj, "F.Cu", even)
    seg(0.945, yj, HX_EVEN, yh, "F.Cu", even)
    # odd: back, direct fan
    seg(-0.02, yf, 0.45, yf, "B.Cu", odd)
    seg(0.45, yf, HX_ODD, yh, "B.Cu", odd)

# ---- outline (tab on left) ----
out_pts = [(0,0),(BW,0),(BW,BH),(0,BH),(0,TAB_B),(-TD+CHAM,TAB_B),(-TD,TAB_B-CHAM),
           (-TD,TAB_T+CHAM),(-TD+CHAM,TAB_T),(0,TAB_T),(0,0)]
edges = []
for i in range(len(out_pts)-1):
    (x1,y1),(x2,y2) = out_pts[i], out_pts[i+1]
    edges.append(f'  (gr_line (start {mm(x1)} {mm(y1)}) (end {mm(x2)} {mm(y2)}) (layer "Edge.Cuts") (width 0.1))')

# mounting holes (footprint pads, no net)
pad("", "np_thru_hole", 1.30, 0.22, 0.126, 0.126, ["*.Cu", "*.Mask"], drill=3.2, shape="circle")
pad("", "np_thru_hole", 1.30, 2.28, 0.126, 0.126, ["*.Cu", "*.Mask"], drill=3.2, shape="circle")

txt(0.62, 0.32, "NS-WSG BUS RISER v1", size=1.1)
txt(0.62, 0.42, "NorthStar Advantage slot breakout", size=0.7)
txt(0.30, 2.32, "pin 1/2 end", size=0.7)
txt(0.30, 0.52, "pin 29/30 end", size=0.7)
txt(0.62, 2.36, "\u00a9 2026 David Troy", size=0.8)
txt(0.62, 2.44, "in memory of Stephen Troy", size=0.8)

nets = "\n".join(f'  (net {i} "P{i}")' for i in range(1, 31))
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
  (setup
    (pad_to_mask_clearance 0.05)
  )
  (net 0 "")
{nets}
  (footprint "riser:all" (layer "F.Cu") (at 0 0)
    (attr through_hole)
{chr(10).join(p if '(net' in p else p for p in pads)}
  )
{chr(10).join(edges)}
{chr(10).join(texts)}
{chr(10).join(S)}
)
'''
open('riser.kicad_pcb','w').write(pcb)
print("wrote riser.kicad_pcb")
