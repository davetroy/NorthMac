#!/usr/bin/env python3
# NS-WSG v1 — placement-level board renders + per-layer fab-style plots,
# true 1:1 (72 pt/in), landscape letter, 8 pages.
# Outline/connector geometry per Documentation/Slot_Bus_Pinout.md, including
# the protruding finger TAB: the card edge is relieved around the connector
# so only the ~0.33"-deep, ~2.0"-long gold tongue enters the slot.
IN=72.0
CW,CH=5.30,3.15                 # main card body, inches (tab protrudes beyond)
TD=0.331                        # tab depth = gold depth
CHAM=0.05                       # tab corner chamfer (insertion lead-in)
OX,OY=0.75*IN,1.9*IN
PITCH,FW=0.125,0.0866
used_even={4,10,12,14,16,18,20,22,24,28,30}
used_odd={1,3,9,11,13,15,17,19,21,23,25,27,29}
names={1:"GND",3:"/IDREQ",4:"+5V",9:"IOA2",10:"IOA3",11:"IOA1",12:"GND",13:"/BRD",14:"IOA0",
15:"8MHZ",16:"/BWR",17:"IO3",18:"/BIORES",19:"IO2",20:"IO4",21:"GND",22:"IO5",23:"IO6",
24:"IO1",25:"IO0",27:"+5V",28:"IO7",29:"/SEL",30:"GND"}

f_top=CH-0.45                   # center of position 15 (pins 29/30)
tab_top=f_top+FW/2+0.08
tab_bot=f_top-14*PITCH-FW/2-0.08

th_pads=[]; f_pads=[]; b_pads=[]; silkF=[]; silkB=[]
for k in range(1,16):
    y=f_top-(15-k)*PITCH
    if 2*k in used_even:
        f_pads.append((-TD,y-FW/2,TD-0.02,FW))
        silkF.append(('text',0.05,y-0.03,f"{2*k} {names[2*k]}",4))
    if 2*k-1 in used_odd:
        b_pads.append((-TD,y-FW/2,TD-0.02,FW))
        silkB.append(('text',0.05,y-0.03,f"{2*k-1} {names[2*k-1]}",4))

def dip(x,y,n,label):
    rows=n//2
    for i in range(rows):
        th_pads.append((x,y+0.05+i*0.1)); th_pads.append((x+0.3,y+0.05+i*0.1))
    L=0.1*rows
    silkF.append(('rect',x+0.03,y,0.24,L))
    silkF.append(('text',x+0.02,y+L+0.03,label,5))

dip(0.65,2.00,20,"U1 LVC245 (IO0-7)")
dip(0.65,0.90,20,"U2 LVC245 (adr/stb)")
dip(1.25,2.00,20,"U3 HCT541 ID=A5")
dip(1.25,0.90,20,"U4 HCT541 ST=57")
dip(1.25,0.05,16,"U5 HCT138")
px,py=1.85,1.22
for i in range(20):
    th_pads.append((px+0.05+i*0.1,py)); th_pads.append((px+0.05+i*0.1,py+0.7))
silkF.append(('rect',px-0.02,py-0.06,2.04,0.83))
silkF.append(('text',px+0.55,py+0.36,"RASPBERRY PI PICO",6))
silkF.append(('text',px+0.30,py+0.24,"NS-WSG FW - drag+drop UF2 over USB",4))
dip(4.05,2.45,8,"U6 PT8211")
for jy in (2.45,2.55,2.65): th_pads.append((4.95,jy))
silkF.append(('rect',4.85,2.35,0.42,0.45)); silkF.append(('text',4.77,2.85,"J1 AUDIO",4))
th_pads+=[(4.98,1.70),(4.98,1.80)]; silkF.append(('text',4.58,1.88,"J2 SPKR MIX",4))
th_pads+=[(4.98,0.30),(4.98,0.40),(4.98,0.50)]; silkF.append(('text',4.58,0.60,"J3 SWD",4))
for cx,cy in [(0.57,2.5),(0.57,1.4),(1.17,2.5),(1.17,1.4),(1.17,0.45),(3.97,2.6),(2.8,1.05)]:
    th_pads+=[(cx,cy),(cx,cy+0.1)]
holes=[(0.25,0.25),(0.25,CH-0.25),(CW-0.25,0.25),(CW-0.25,CH-0.25)]
silkF.append(('text',1.80,2.95,"NS-WSG v1 - NorthStar Advantage wavetable sound card",6))
silkF.append(('text',1.80,2.83,"board ID 0xA5 - spec NSWSG.md - original design",4))
silkB.append(('text',1.5,2.9,"NS-WSG v1 solder side",6))

def esc(t): return t.replace('(','\\(').replace(')','\\)')
class P:
    def __init__(s,title,sub=""):
        s.c=["0.4 w 0 g",
            f"BT /F1 10 Tf 40 560 Td ({esc(title)}) Tj ET",
            f"BT /F1 7 Tf 40 548 Td ({esc(sub)}) Tj ET",
            f"BT /F1 7 Tf 40 536 Td (PRINT AT 100% LANDSCAPE - ruler must measure true) Tj ET",
            "40 520 m 184 520 l S"]
        for i in range(17):
            s.c.append(f"{40+i*9} 520 m {40+i*9} {520+(9 if i%8==0 else 4.5)} l S")
    def g(s,r,gg,b,stroke=False): s.c.append(f"{r} {gg} {b} {'RG' if stroke else 'rg'}")
    def rect(s,x,y,w,h,op='f'): s.c.append(f"{OX+x*IN:.2f} {OY+y*IN:.2f} {w*IN:.2f} {h*IN:.2f} re {op}")
    def circ(s,x,y,r,op='f'):
        X,Y,R=OX+x*IN,OY+y*IN,r*IN; k=0.5523*R
        s.c.append(f"{X+R:.2f} {Y:.2f} m {X+R:.2f} {Y+k:.2f} {X+k:.2f} {Y+R:.2f} {X:.2f} {Y+R:.2f} c {X-k:.2f} {Y+R:.2f} {X-R:.2f} {Y+k:.2f} {X-R:.2f} {Y:.2f} c {X-R:.2f} {Y-k:.2f} {X-k:.2f} {Y-R:.2f} {X:.2f} {Y-R:.2f} c {X+k:.2f} {Y-R:.2f} {X+R:.2f} {Y-k:.2f} {X+R:.2f} {Y:.2f} c {op}")
    def t(s,x,y,txt,size=5): s.c.append(f"BT /F1 {size} Tf {OX+x*IN:.2f} {OY+y*IN:.2f} Td ({esc(txt)}) Tj ET")
    def poly(s,pts,op='f'):
        s.c.append(f"{OX+pts[0][0]*IN:.2f} {OY+pts[0][1]*IN:.2f} m "+
            " ".join(f"{OX+x*IN:.2f} {OY+y*IN:.2f} l" for x,y in pts[1:])+f" h {op}")

def outline_pts(mirror=False):
    pts=[(0,0),(CW,0),(CW,CH),(0,CH),
         (0,tab_top),(-TD+CHAM,tab_top),(-TD,tab_top-CHAM),
         (-TD,tab_bot+CHAM),(-TD+CHAM,tab_bot),(0,tab_bot)]
    if mirror: pts=[(CW-x,y) for x,y in pts]
    return pts
def MX(x,w=0): return CW-x-w
def draw_holes(p,mirror=False):
    for hx,hy in holes:
        x=MX(hx) if mirror else hx
        p.g(1,1,1); p.circ(x,hy,0.07,'f'); p.g(0,0,0,True); p.circ(x,hy,0.07,'S')

pages=[]
# TOP render
p=P("NS-WSG v1 - TOP assembly render (component side, finger tab left)",
    "gold = exposed copper, green = mask, white = silk; edge relieved around the connector tab")
p.g(0.16,0.42,0.22); p.poly(outline_pts(),'f'); p.g(0,0,0,True); p.poly(outline_pts(),'S')
p.g(0.85,0.68,0.15)
for x,y,w,h in f_pads: p.rect(x,y,w,h)
for x,y in th_pads: p.g(0.85,0.68,0.15); p.circ(x,y,0.032); p.g(0.16,0.42,0.22); p.circ(x,y,0.014)
draw_holes(p)
for e in silkF:
    if e[0]=='rect': p.g(1,1,1,True); p.rect(e[1],e[2],e[3],e[4],'S')
    else: p.g(1,1,1); p.t(e[1],e[2],e[3],e[4])
pages.append(p)
# BOTTOM render (mirrored)
p=P("NS-WSG v1 - BOTTOM assembly render (solder side, AS SEEN FROM BACK - tab right)",
    "x-mirrored: overlay directly on the card's back")
p.g(0.16,0.42,0.22); p.poly(outline_pts(True),'f'); p.g(0,0,0,True); p.poly(outline_pts(True),'S')
p.g(0.85,0.68,0.15)
for x,y,w,h in b_pads: p.rect(MX(x,w),y,w,h)
for x,y in th_pads: p.g(0.85,0.68,0.15); p.circ(MX(x),y,0.032); p.g(0.16,0.42,0.22); p.circ(MX(x),y,0.014)
draw_holes(p,True)
for e in silkB: p.g(1,1,1); p.t(MX(e[1])-0.6,e[2],e[3],e[4])
pages.append(p)
# layer plots
def cu(title,pads,mirror):
    p=P(title,"black = copper features; pour added at routing")
    p.g(0,0,0,True); p.poly(outline_pts(mirror),'S'); p.g(0,0,0)
    for x,y,w,h in pads: p.rect(MX(x,w) if mirror else x,y,w,h)
    for x,y in th_pads:
        X=MX(x) if mirror else x
        p.circ(X,y,0.032); p.g(1,1,1); p.circ(X,y,0.014); p.g(0,0,0)
    draw_holes(p,mirror); return p
pages.append(cu("F.Cu - front copper (pads only, pre-route)",f_pads,False))
p=P("F.Mask - front solder mask (black = OPENINGS)","tab + all pads exposed")
p.g(0,0,0,True); p.poly(outline_pts(),'S'); p.g(0,0,0)
p.rect(-TD,tab_bot,TD,tab_top-tab_bot)     # whole tab unmasked
for x,y in th_pads: p.circ(x,y,0.036)
draw_holes(p); pages.append(p)
p=P("F.SilkS - front silkscreen","")
p.g(0,0,0,True); p.poly(outline_pts(),'S'); p.g(0,0,0)
for e in silkF:
    if e[0]=='rect': p.g(0,0,0,True); p.rect(e[1],e[2],e[3],e[4],'S'); p.g(0,0,0)
    else: p.t(e[1],e[2],e[3],e[4])
pages.append(p)
pages.append(cu("B.Cu - back copper, MIRRORED (as seen from back)",b_pads,True))
p=P("B.Mask - back solder mask, MIRRORED (black = OPENINGS)","")
p.g(0,0,0,True); p.poly(outline_pts(True),'S'); p.g(0,0,0)
p.rect(MX(-TD,TD),tab_bot,TD,tab_top-tab_bot)
for x,y in th_pads: p.circ(MX(x),y,0.036)
draw_holes(p,True); pages.append(p)
p=P("B.SilkS - back silkscreen, MIRRORED","")
p.g(0,0,0,True); p.poly(outline_pts(True),'S'); p.g(0,0,0)
for e in silkB: p.t(MX(e[1])-0.6,e[2],e[3],e[4])
pages.append(p)

n=len(pages)
objs=["<< /Type /Catalog /Pages 2 0 R >>",
f"<< /Type /Pages /Kids [{' '.join(f'{3+i} 0 R' for i in range(n))}] /Count {n} >>"]
font_id=3+2*n
for i in range(n):
    objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 792 612] /Contents {3+n+i} 0 R /Resources << /Font << /F1 {font_id} 0 R >> >> >>")
for pg in pages:
    stream="\n".join(pg.c)
    objs.append(f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream")
objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
out="%PDF-1.4\n"; offs=[]
for i,o in enumerate(objs,1):
    offs.append(len(out)); out+=f"{i} 0 obj\n{o}\nendobj\n"
xref=len(out)
out+=f"xref\n0 {n and len(objs)+1}\n0000000000 65535 f \n"
for off in offs: out+=f"{off:010d} 00000 n \n"
out+=f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF"
open('nswsg_layers_1to1.pdf','w').write(out)
print(f"wrote nswsg_layers_1to1.pdf ({n} pages)")
