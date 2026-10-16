"""Trace the original icon into smooth outlines: body and leaf as cubic Bezier paths in tile space."""
import json
from pathlib import Path
import numpy as np
from PIL import Image
from scipy import ndimage
from skimage import measure, morphology

SC = 88 / 890
def to_tile(p): return (6 + (p[0] - 180) * SC, 24 + (p[1] - 338) * SC)

HERE = Path(__file__).resolve().parent
ORIGINAL = HERE / '../../docs/assets/container-compose-icon.png'

alpha = np.asarray(Image.open(ORIGINAL).convert('RGBA'))[:, :, 3] >= 128
labels, _ = ndimage.label(alpha)

def outline(seed, close_r, sigma):
    comp = labels == labels[seed[1], seed[0]]
    comp = ndimage.binary_fill_holes(morphology.closing(comp, morphology.disk(close_r)))
    soft = ndimage.gaussian_filter(comp.astype(float), sigma)
    c = max(measure.find_contours(soft, 0.5), key=len)       # (row, col)
    return np.array([[p[1], p[0]] for p in c])                # (x, y)

# --- Schneider curve fitting -------------------------------------------------
def bez(ctrl, t):
    t = t[:, None]
    return ((1-t)**3*ctrl[0] + 3*(1-t)**2*t*ctrl[1] + 3*(1-t)*t**2*ctrl[2] + t**3*ctrl[3])
def bez_d(ctrl, t):
    t = t[:, None]
    return 3*(1-t)**2*(ctrl[1]-ctrl[0]) + 6*(1-t)*t*(ctrl[2]-ctrl[1]) + 3*t**2*(ctrl[3]-ctrl[2])
def bez_dd(ctrl, t):
    t = t[:, None]
    return 6*(1-t)*(ctrl[2]-2*ctrl[1]+ctrl[0]) + 6*t*(ctrl[3]-2*ctrl[2]+ctrl[1])
def chord(pts):
    d = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))])
    return d / d[-1]
def generate(pts, u, t1, t2):
    A1, A2 = np.outer(3*(1-u)**2*u, t1), np.outer(3*(1-u)*u**2, t2)
    C = np.array([[np.sum(A1*A1), np.sum(A1*A2)], [np.sum(A1*A2), np.sum(A2*A2)]])
    base = bez(np.array([pts[0], pts[0], pts[-1], pts[-1]]), u)
    tmp = pts - base
    X = np.array([np.sum(A1*tmp), np.sum(A2*tmp)])
    det = C[0, 0]*C[1, 1] - C[0, 1]**2
    seg = np.linalg.norm(pts[-1] - pts[0])
    if abs(det) > 1e-12:
        a1 = (X[0]*C[1, 1] - X[1]*C[0, 1]) / det
        a2 = (C[0, 0]*X[1] - C[0, 1]*X[0]) / det
    else:
        a1 = a2 = seg / 3
    if a1 < 1e-6*seg or a2 < 1e-6*seg:
        a1 = a2 = seg / 3
    return np.array([pts[0], pts[0]+t1*a1, pts[-1]+t2*a2, pts[-1]])
def reparam(ctrl, pts, u):
    d = bez(ctrl, u) - pts
    num = np.sum(d * bez_d(ctrl, u), axis=1)
    den = np.sum(bez_d(ctrl, u)**2 + d*bez_dd(ctrl, u), axis=1)
    return np.clip(u - np.where(den != 0, num/den, 0), 0, 1)
def fit(pts, t1, t2, err):
    if len(pts) == 2:
        dist = np.linalg.norm(pts[1]-pts[0]) / 3
        return [np.array([pts[0], pts[0]+t1*dist, pts[1]+t2*dist, pts[1]])]
    u = chord(pts)
    ctrl = generate(pts, u, t1, t2)
    for _ in range(20):
        dists = np.sum((bez(ctrl, u) - pts)**2, axis=1)
        if dists.max() < err**2:
            return [ctrl]
        u = reparam(ctrl, pts, u)
        ctrl = generate(pts, u, t1, t2)
    dists = np.sum((bez(ctrl, u) - pts)**2, axis=1)
    if dists.max() < err**2:
        return [ctrl]
    split = int(np.clip(np.argmax(dists), 1, len(pts)-2))
    tc = pts[split-1] - pts[split+1]; tc /= np.linalg.norm(tc)
    return fit(pts[:split+1], t1, tc, err) + fit(pts[split:], -tc, t2, err)
def unit(v): return v / np.linalg.norm(v)

def closed_fit(pts, corners, err, look=6):
    """Fit a closed outline, splitting at the given corner points so they stay crisp."""
    pts = pts[:-1] if np.allclose(pts[0], pts[-1]) else pts
    idx = sorted({int(np.argmin(np.linalg.norm(pts - np.array(c), axis=1))) for c in corners})
    pts = np.roll(pts, -idx[0], axis=0); idx = [(i - idx[0]) % len(pts) for i in idx] + [len(pts)]
    pts = np.vstack([pts, pts[:1]])
    segs = []
    for a, b in zip(idx, idx[1:]):
        p = pts[a:b+1]
        t1 = unit(p[min(look, len(p)-1)] - p[0]); t2 = unit(p[max(-look-1, -len(p))] - p[-1])
        segs += fit(p, t1, t2, err)
    return segs

def path_d(segs):
    f = lambda v: f'{v:.2f}'.rstrip('0').rstrip('.')
    p0 = to_tile(segs[0][0]); d = f'M{f(p0[0])} {f(p0[1])}'
    for s in segs:
        c1, c2, e = to_tile(s[1]), to_tile(s[2]), to_tile(s[3])
        d += f' C{f(c1[0])} {f(c1[1])} {f(c2[0])} {f(c2[1])} {f(e[0])} {f(e[1])}'
    return d + ' Z', len(segs)

body = outline((630, 740), close_r=14, sigma=2.5)
leaf = outline((788, 194), close_r=6, sigma=1.5)
body_d, nb = path_d(closed_fit(body, corners=[(626, 386), (620, 1126)], err=1.5))
leaf_d, nl = path_d(closed_fit(leaf, corners=[(922, 56), (655, 352)], err=1.2))
json.dump({'body': body_d, 'leaf': leaf_d}, open(HERE / 'outline.json', 'w'))
print(f'body: {len(body)} contour points -> {nb} curves | leaf: {len(leaf)} -> {nl} curves')
