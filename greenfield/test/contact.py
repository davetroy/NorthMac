import struct, zlib
W,H,NC = 640,240,80
GREEN=(112,255,112); GAP=8
raws=['c1.raw','c2.raw','c3.raw']
def rows_for(path):
    d=open(path,'rb').read(); out=bytearray()
    for y in range(H):
        out.append(0)
        for x in range(W):
            b=d[(x>>3)*256+y]; out += bytes(GREEN) if (b>>(7-(x&7)))&1 else b'\x00\x00\x00'
    return out
gaprow = b'\x00'+ (b'\x18\x20\x18'*W)  # faint separator line repeated
sheet=bytearray()
for i,p in enumerate(raws):
    sheet+=rows_for(p)
    if i<len(raws)-1:
        for _ in range(GAP): sheet+= b'\x00'+(b'\x10\x14\x10'*W)
TH=H*len(raws)+GAP*(len(raws)-1)
def chunk(t,p): c=t+p; return struct.pack('>I',len(p))+c+struct.pack('>I',zlib.crc32(c)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',W,TH,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(sheet),9))+chunk(b'IEND',b'')
open('greenfield_contact.png','wb').write(png)
print('wrote greenfield_contact.png', W,'x',TH,'(3 distinct gallery canvases)')
