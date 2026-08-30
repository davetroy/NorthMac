#!/usr/bin/env python3
# Regenerates edge_check_1to1.pdf — a true-scale (72 pt/in) overlay print
# for verifying the slot-edge footprint against a real SIO card.
PITCH=0.125*72
FW=(2.2/25.4)*72
FD=(8.4/25.4)*72
N=15
sio_unplated_even={2,4,6,8,12}
sio_unplated_odd={21}
def esc(t): return t.replace('(','\\(').replace(')','\\)')
c=[]
def rect(x,y,w,h,fill=True): c.append(f"{x:.2f} {y:.2f} {w:.2f} {h:.2f} re {'f' if fill else 'S'}")
def dashed(on=True): c.append("[3 3] 0 d" if on else "[] 0 d")
def text(x,y,s,size=8): c.append(f"BT /F1 {size} Tf {x:.2f} {y:.2f} Td ({esc(s)}) Tj ET")
def line(x1,y1,x2,y2): c.append(f"{x1:.2f} {y1:.2f} m {x2:.2f} {y2:.2f} l S")
c.append("0.5 w 0 g")
text(72,740,"NorthStar Advantage slot edge - 1:1 print check.  PRINT AT 100% / ACTUAL SIZE (no fit-to-page).",9)
text(72,726,"Lay over the SIO card in the same orientation; solid fingers must align with gold,",9)
text(72,714,"dashed outlines must align with the SIO's unplated (empty) positions.",9)
rx,ry=72,660
line(rx,ry,rx+3*72,ry)
for i in range(0,25):
    x=rx+i*9
    line(x,ry,x,ry+(10 if i%8==0 else 5))
text(rx,ry+14,'scale check: ticks every 0.125", long ticks every 1.000"',8)
def row(y,label,unplated,pins):
    text(72,y+FD+18,label,9)
    for k in range(1,N+1):
        x=90+(k-1)*PITCH
        pin=pins(k)
        if pin in unplated:
            dashed(True); rect(x-FW/2,y,FW,FD,fill=False); dashed(False)
        else:
            rect(x-FW/2,y,FW,FD,fill=True)
        text(x-6,y-11,str(pin),6)
row(560,"COMPONENT SIDE up, fingers pointing AWAY from you: even pins, 2 left ... 30 right",
    sio_unplated_even, lambda k:2*k)
row(440,"SOLDER SIDE up, fingers pointing AWAY from you: odd pins, 29 left ... 1 right",
    sio_unplated_odd, lambda k:29-2*(k-1))
text(72,400,"Span check: first-to-last finger centers = 1.750 in.  Connector pitch 0.125 in.",8)
text(72,388,"If anything misaligns by more than half a finger width, STOP and re-measure before fab.",8)
stream="\n".join(c)
objs=["<< /Type /Catalog /Pages 2 0 R >>",
"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream",
"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
out="%PDF-1.4\n"; offs=[]
for i,o in enumerate(objs,1):
    offs.append(len(out)); out+=f"{i} 0 obj\n{o}\nendobj\n"
xref=len(out)
out+=f"xref\n0 {len(objs)+1}\n0000000000 65535 f \n"
for off in offs: out+=f"{off:010d} 00000 n \n"
out+=f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF"
open('edge_check_1to1.pdf','w').write(out)
print("wrote edge_check_1to1.pdf")
