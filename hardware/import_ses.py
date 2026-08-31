#!/usr/bin/env python3
# Injects freerouting's card.ses wires/vias into card.kicad_pcb -> card_routed.kicad_pcb
import re, sys
ses = open('card.ses').read()
board = open('card.kicad_pcb').read()
# net name -> id from the board file
nid = dict(re.findall(r'\(net (\d+) "([^"]+)"\)', board))
nid = {name: int(i) for i, name in re.findall(r'\(net (\d+) "([^"]+)"\)', board)}

def tok(s):
    return re.findall(r'\(|\)|[^\s()]+', s)
t = tok(ses)
i = 0
out = []
def mmx(v): return round(int(v)/10000.0, 4)
def mmy(v): return round(-int(v)/10000.0, 4)
nsegs = nvias = 0
while i < len(t):
    if t[i] == '(' and i+1 < len(t) and t[i+1] == 'net':
        net = t[i+2]
        depth = 1
        j = i+3
        cur = nid.get(net)
        while j < len(t) and depth > 0:
            if t[j] == '(':
                if t[j+1] == 'path' and cur is not None:
                    layer = t[j+2]; width = int(t[j+3])/10000.0
                    if 0.15 <= width < 0.2: width = 0.2   # kiss min-width
                    pts = []
                    k = j+4
                    while t[k] != ')':
                        pts.append((t[k], t[k+1])); k += 2
                    for a in range(len(pts)-1):
                        (x1,y1),(x2,y2) = pts[a], pts[a+1]
                        out.append(f'  (segment (start {mmx(x1)} {mmy(y1)}) (end {mmx(x2)} {mmy(y2)}) (width {width}) (layer "{layer}") (net {cur}))')
                        nsegs += 1
                    depth += 1; j += 1
                elif t[j+1] == 'via' and cur is not None:
                    # (via "name" x y)
                    x, y = t[j+3], t[j+4]
                    out.append(f'  (via (at {mmx(x)} {mmy(y)}) (size 0.6) (drill 0.3) (layers "F.Cu" "B.Cu") (net {cur}))')
                    nvias += 1
                    depth += 1; j += 1
                else:
                    depth += 1; j += 1
            elif t[j] == ')':
                depth -= 1; j += 1
            else:
                j += 1
        i = j
    else:
        i += 1
assert board.rstrip().endswith(')')
routed = board.rstrip()[:-1] + "\n".join(out) + "\n)\n"
open('card_routed.kicad_pcb','w').write(routed)
print(f"injected {nsegs} segments, {nvias} vias")
