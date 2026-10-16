"""Build the flat SVG logo: the traced outline from trace.py filled with a wall of containers.

Writes apple-wall.svg (64px and up), apple-small.svg (32px and below), and
overlay.svg (the outline drawn over the original icon, for checking the trace).
"""
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
ORIGINAL = Path('../../docs/assets/container-compose-icon.png')   # relative to HERE, for overlay.svg

# Colours sampled from the original icon: (face, rib/shadow) per container colour.
C={'R':('#f6574c','#c63f35'),'D':('#5c6570','#434b54'),'L':('#cbd2d9','#a3abb3'),'B':('#2092f5','#1670c2')}
WHITE,SEAM='#edf1f4','#2b3138'
H=12.4; GAP=1.1                                  # row height and gap between containers, in tile units
def f(v): return f'{v:.2f}'.rstrip('0').rstrip('.')
# Same mapping as trace.py: original-icon pixels into the tile space.
SC=88/890
def M(x,y): return 6+(x-180)*SC, 24+(y-338)*SC
_O=json.load(open(HERE/'outline.json'))          # smooth Bezier outlines from trace.py
APPLE=_O['body']
LEAF=_O['leaf']
LB,LT=M(662,346),M(918,60)                      # leaf base and tip
# ---- app glyphs: simplified hints of each project's mark, centred at (cx, cy), size s
def poly(n,cx,cy,r,rot=-90):
    return ' '.join(f'{f(cx+r*math.cos(math.radians(rot+360*i/n)))},{f(cy+r*math.sin(math.radians(rot+360*i/n)))}' for i in range(n))
def ubuntu(cx,cy,s):
    r=s*0.5; out=f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r)}" fill="#e95420"/>'
    out+=f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r*0.5)}" fill="none" stroke="#fff" stroke-width="{f(r*0.2)}"/>'
    for a in (0,120,240):
        x=cx+r*0.72*math.cos(math.radians(a-90)); y=cy+r*0.72*math.sin(math.radians(a-90))
        out+=f'<circle cx="{f(x)}" cy="{f(y)}" r="{f(r*0.24)}" fill="#e95420"/><circle cx="{f(x)}" cy="{f(y)}" r="{f(r*0.15)}" fill="#fff"/>'
    return out
def kubernetes(cx,cy,s):
    r=s*0.52; out=f'<polygon points="{poly(7,cx,cy,r)}" fill="#326ce5" stroke="#326ce5" stroke-width="{f(r*0.2)}" stroke-linejoin="round"/>'
    out+=f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r*0.42)}" fill="none" stroke="#fff" stroke-width="{f(r*0.13)}"/>'
    for i in range(7):
        a=math.radians(-90+360*i/7)
        out+=f'<line x1="{f(cx+r*0.12*math.cos(a))}" y1="{f(cy+r*0.12*math.sin(a))}" x2="{f(cx+r*0.7*math.cos(a))}" y2="{f(cy+r*0.7*math.sin(a))}" stroke="#fff" stroke-width="{f(r*0.11)}" stroke-linecap="round"/>'
    return out
def fedora(cx,cy,s):
    r=s*0.5; w=r*0.22
    return (f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r)}" fill="#51a2da"/>'
            f'<path d="M{f(cx+r*0.05)} {f(cy+r*0.62)} V{f(cy-r*0.15)} A{f(r*0.32)} {f(r*0.32)} 0 0 1 {f(cx+r*0.5)} {f(cy-r*0.45)}" fill="none" stroke="#fff" stroke-width="{f(w)}" stroke-linecap="round"/>'
            f'<line x1="{f(cx-r*0.3)}" y1="{f(cy+r*0.08)}" x2="{f(cx+r*0.4)}" y2="{f(cy+r*0.08)}" stroke="#fff" stroke-width="{f(w)}" stroke-linecap="round"/>')
def alpine(cx,cy,s):
    r=s*0.52
    return (f'<polygon points="{poly(6,cx,cy,r,rot=0)}" fill="#0d597f"/>'
            f'<polyline points="{f(cx-r*0.62)},{f(cy+r*0.3)} {f(cx-r*0.18)},{f(cy-r*0.25)} {f(cx+r*0.12)},{f(cy+r*0.08)} {f(cx+r*0.3)},{f(cy-r*0.12)} {f(cx+r*0.62)},{f(cy+r*0.3)}" fill="none" stroke="#fff" stroke-width="{f(r*0.16)}" stroke-linejoin="round" stroke-linecap="round"/>')
def redis(cx,cy,s):
    w=s*0.5; h=s*0.14; out=''
    for i,dy in enumerate((0.28,0,-0.28)):
        y=cy+s*dy
        out+=(f'<polygon points="{f(cx-w)},{f(y)} {f(cx)},{f(y-h)} {f(cx+w)},{f(y)} {f(cx)},{f(y+h)}" fill="#dc382d"/>'
              f'<polygon points="{f(cx-w)},{f(y)} {f(cx)},{f(y+h)} {f(cx)},{f(y+h*1.7)} {f(cx-w)},{f(y+h*0.7)}" fill="#a41e11"/>'
              f'<polygon points="{f(cx+w)},{f(y)} {f(cx)},{f(y+h)} {f(cx)},{f(y+h*1.7)} {f(cx+w)},{f(y+h*0.7)}" fill="#c12a20"/>')
    return out
def arch(cx,cy,s):
    r=s*0.55
    return (f'<path d="M{f(cx)} {f(cy-r)} L{f(cx+r*0.9)} {f(cy+r*0.85)} Q{f(cx+r*0.3)} {f(cy+r*0.1)} {f(cx)} {f(cy+r*0.15)} '
            f'Q{f(cx-r*0.3)} {f(cy+r*0.1)} {f(cx-r*0.9)} {f(cy+r*0.85)} Z" fill="#1793d1"/>')
def nginx(cx,cy,s):
    r=s*0.54
    return (f'<polygon points="{poly(6,cx,cy,r)}" fill="#009639"/>'
            f'<polyline points="{f(cx-r*0.32)},{f(cy+r*0.42)} {f(cx-r*0.32)},{f(cy-r*0.42)} {f(cx+r*0.32)},{f(cy+r*0.42)} {f(cx+r*0.32)},{f(cy-r*0.42)}" fill="none" stroke="#fff" stroke-width="{f(r*0.2)}" stroke-linejoin="round" stroke-linecap="round"/>')
def prometheus(cx,cy,s):
    r=s*0.5
    P=lambda a,b:f'{f(cx+a*r)} {f(cy+b*r)}'
    flame=(f'M{P(0.04,-0.74)} C{P(0.16,-0.46)} {P(0.52,-0.32)} {P(0.47,0.06)} C{P(0.44,0.3)} {P(0.24,0.36)} {P(0,0.36)} '
           f'C{P(-0.24,0.36)} {P(-0.45,0.28)} {P(-0.46,0.04)} C{P(-0.47,-0.2)} {P(-0.3,-0.3)} {P(-0.2,-0.48)} '
           f'C{P(-0.17,-0.3)} {P(-0.1,-0.22)} {P(-0.03,-0.24)} C{P(-0.08,-0.42)} {P(-0.04,-0.6)} {P(0.04,-0.74)} Z')
    return (f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r)}" fill="#e6522c"/><path d="{flame}" fill="#fff"/>'
            f'<rect x="{f(cx-r*0.46)}" y="{f(cy+r*0.46)}" width="{f(r*0.92)}" height="{f(r*0.15)}" rx="{f(r*0.07)}" fill="#fff"/>')
def mongodb(cx,cy,s):
    r=s*0.56
    return (f'<path d="M{f(cx)} {f(cy-r)} C{f(cx+r*0.62)} {f(cy-r*0.35)} {f(cx+r*0.55)} {f(cy+r*0.45)} {f(cx)} {f(cy+r*0.8)} C{f(cx-r*0.55)} {f(cy+r*0.45)} {f(cx-r*0.62)} {f(cy-r*0.35)} {f(cx)} {f(cy-r)} Z" fill="#47a248"/>'
            f'<line x1="{f(cx)}" y1="{f(cy-r*0.6)}" x2="{f(cx)}" y2="{f(cy+r*1.0)}" stroke="#2f7a30" stroke-width="{f(r*0.12)}" stroke-linecap="round"/>')
def nextcloud(cx,cy,s):
    r=s*0.5
    return (f'<rect x="{f(cx-r)}" y="{f(cy-r*0.75)}" width="{f(2*r)}" height="{f(1.5*r)}" rx="{f(r*0.3)}" fill="#0082c9"/>'
            f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r*0.32)}" fill="none" stroke="#fff" stroke-width="{f(r*0.13)}"/>'
            f'<circle cx="{f(cx-r*0.62)}" cy="{f(cy)}" r="{f(r*0.18)}" fill="none" stroke="#fff" stroke-width="{f(r*0.11)}"/>'
            f'<circle cx="{f(cx+r*0.62)}" cy="{f(cy)}" r="{f(r*0.18)}" fill="none" stroke="#fff" stroke-width="{f(r*0.11)}"/>')
APPS={'ubuntu':ubuntu,'kubernetes':kubernetes,'fedora':fedora,'alpine':alpine,'redis':redis,'arch':arch,'nginx':nginx,'prometheus':prometheus,'mongodb':mongodb,'nextcloud':nextcloud}
W={'n':0.75,'m':1.1,'w':1.55}
ROWS=[(-1,['Lm','Dn','Lw','Dn','Lw','Rn','Lm','Dn']),
      (-3,['Rn','Rw','ubuntu','Dw','kubernetes','fedora','Rn']),
      (-3,['Dn','Bm','alpine','Lw','redis','arch','Lm','Bm']),
      (1,['Ln','Rn','Dw','nginx','Rm','prometheus','Lw','Dn']),
      (-2,['Rn','Dw','mongodb','Lm','nextcloud','Dw','Bn']),
      (0,['Dn','Rm','Ln','Rw','Dn','Lw','Rm','Dn']),
      (-1,['Lw','Rn','Dw','Ln','Rw','Lm'])]
def tile(x,y,code):
    if code in APPS:
        w=1.05*H; bw,bh=w-GAP,H-GAP
        return w,(f'<rect x="{f(x)}" y="{f(y)}" width="{f(bw)}" height="{f(bh)}" rx="1.1" fill="{WHITE}"/>'
                  + APPS[code](x+bw/2,y+bh/2,bh*0.62)), (x,x+bw,code)
    col,kind=code[0],code[1]; fill,dark=C[col]; w=W[kind]*H; bw,bh=w-GAP,H-GAP
    out=f'<rect x="{f(x)}" y="{f(y)}" width="{f(bw)}" height="{f(bh)}" rx="1.1" fill="{fill}"/>'
    if kind=='n':   # door end: two pairs of lock bars
        for fx in (0.3,0.42,0.58,0.7):
            out+=f'<rect x="{f(x+bw*fx-0.35)}" y="{f(y+1.6)}" width="0.7" height="{f(bh-3.2)}" rx="0.35" fill="{dark}"/>'
        out+=f'<rect x="{f(x+bw*0.5-0.2)}" y="{f(y+1)}" width="0.4" height="{f(bh-2)}" fill="{dark}" opacity="0.7"/>'
    else:           # side: corrugation ribs
        n=max(3,round(bw/2.6))
        for i in range(1,n):
            out+=f'<rect x="{f(x+bw*i/n-0.35)}" y="{f(y+1.5)}" width="0.7" height="{f(bh-3)}" rx="0.35" fill="{dark}" opacity="0.75"/>'
    out+=f'<rect x="{f(x)}" y="{f(y)}" width="{f(bw)}" height="0.9" rx="0.45" fill="#fff" opacity="0.22"/>'
    return w,out,None
tiles=''; apps=[]
for r,(sx,codes) in enumerate(ROWS):
    x=sx; y=24+r*H
    for code in codes:
        w,svg,app=tile(x,y,code); tiles+=svg
        if app: apps.append((r,round(app[0],1),round(app[1],1),app[2]))
        x+=w
for a in apps: print('app',a)
# Leaf: split lengthwise along base-to-tip, grey on the left, red on the right, with ribs across each half.
(bx,by),(tx,ty)=LB,LT
dx,dy=tx-bx,ty-by; L=math.hypot(dx,dy); ux,uy=dx/L,dy/L; nx,ny=-uy,ux
far=40
def side(sign,color): return f'<polygon points="{f(bx)},{f(by)} {f(tx)},{f(ty)} {f(tx+sign*nx*far)},{f(ty+sign*ny*far)} {f(bx+sign*nx*far)},{f(by+sign*ny*far)}" fill="{color}"/>'
def ribs(sign,color):
    out=''
    for i in range(1,6):
        px,py=bx+dx*i/6,by+dy*i/6
        out+=f'<line x1="{f(px+sign*nx*0.6)}" y1="{f(py+sign*ny*0.6)}" x2="{f(px+sign*nx*4.5)}" y2="{f(py+sign*ny*4.5)}" stroke="{color}" stroke-width="0.9" stroke-linecap="round"/>'
    return out
def leaf(detail,cid):
    mx,my=bx+dx*0.45,by+dy*0.45                     # where the cross seam meets the midline
    def quad(a,b,sign,color):
        (ax,ay),(cx_,cy_)=a,b
        return f'<polygon points="{f(ax)},{f(ay)} {f(cx_)},{f(cy_)} {f(cx_+sign*nx*far)},{f(cy_+sign*ny*far)} {f(ax+sign*nx*far)},{f(ay+sign*ny*far)}" fill="{color}"/>'
    lo=(bx-dx,by-dy); mid=(mx,my); hi=(tx+dx,ty+dy)
    panels=(quad(lo,mid,-1,C['R'][0])+quad(lo,mid,1,C['R'][0])+quad(mid,hi,-1,C['D'][0])+quad(mid,hi,1,C['L'][0]))
    seams=(f'<line x1="{f(bx)}" y1="{f(by)}" x2="{f(tx)}" y2="{f(ty)}" stroke="{SEAM}" stroke-width="0.9"/>'
           f'<line x1="{f(mx-nx*20)}" y1="{f(my-ny*20)}" x2="{f(mx+nx*20)}" y2="{f(my+ny*20)}" stroke="{SEAM}" stroke-width="0.9"/>')
    rib=''
    if detail:
        for i in range(1,8):
            t=i/8
            if abs(t-0.45)<0.05: continue
            px,py=bx+dx*t,by+dy*t
            for sign,col in ((-1,C['R'][1] if t<0.45 else C['D'][1]),(1,C['R'][1] if t<0.45 else C['L'][1])):
                rib+=f'<line x1="{f(px+sign*nx*0.8)}" y1="{f(py+sign*ny*0.8)}" x2="{f(px+sign*nx*6)}" y2="{f(py+sign*ny*6)}" stroke="{col}" stroke-width="0.8" stroke-linecap="round"/>'
    return (f'<path d="{LEAF}" fill="{SEAM}" stroke="{SEAM}" stroke-width="{0.6 if detail else 1.2}" stroke-linejoin="round"/>'
            f'<clipPath id="{cid}"><path d="{LEAF}"/></clipPath><g clip-path="url(#{cid})">{panels}{rib}{seams}</g>')
def wrap(inner,cid,stroke,leafsvg):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="2 -6 96 113" role="img" aria-label="container compose"><title>container compose</title>'
            f'<defs><clipPath id="{cid}"><path d="{APPLE}"/></clipPath></defs>'
            f'<path d="{APPLE}" fill="{SEAM}" stroke="{SEAM}" stroke-width="{stroke}" stroke-linejoin="round"/>'
            f'<g clip-path="url(#{cid})">{inner}</g>{leafsvg}</svg>\n')
open(HERE/'apple-wall.svg','w').write(wrap(tiles,'apple',0.6,leaf(True,'leaf')))
# Small variant: same silhouette and leaf, bigger plain containers.
HS=17.5; GS=1.8
SROWS=[(-2,'LDRLDL'),(4,'RLBDLR'),(-6,'DLRLDB'),(1,'LRDLRD'),(-3,'RDLBLR')]
small=''
for r,(sx,cols) in enumerate(SROWS):
    x=sx; y=24+r*HS
    for i,c in enumerate(cols):
        w=HS*(1.45 if (i+r)%3 else 1.05)
        small+=f'<rect x="{f(x)}" y="{f(y)}" width="{f(w-GS)}" height="{f(HS-GS)}" rx="1.8" fill="{C[c][0]}"/>'
        x+=w
open(HERE/'apple-small.svg','w').write(wrap(small,'sapple',1.2,leaf(False,'sleaf')))

# Check image: the outline over the original icon, framed the same way as the logo.
x0,y0,w=6-180*SC,24-338*SC,1254*SC
open(HERE/'overlay.svg','w').write(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="2 -6 96 113" width="700" height="824">'
    f'<image href="{ORIGINAL.as_posix()}" x="{f(x0)}" y="{f(y0)}" width="{f(w)}" height="{f(w)}" opacity="0.85"/>'
    f'<path d="{APPLE}" fill="none" stroke="#ff00aa" stroke-width="0.35"/>'
    f'<path d="{LEAF}" fill="none" stroke="#ff00aa" stroke-width="0.35"/></svg>\n')
