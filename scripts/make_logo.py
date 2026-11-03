#!/usr/bin/env python3
"""Generates assets/logo.svg: a cut-off dino tail with a steel disk on
its cut end, stuck to a steel plate along the right edge like a fridge magnet
(and like the panel's tab on the screen edge). Run: python3 scripts/make_logo.py"""
import math
from pathlib import Path

def bez(p0, p1, p2, p3, t):
    u = 1 - t
    return tuple(u**3*a + 3*u*u*t*b + 3*u*t*t*c + t**3*d for a, b, c, d in zip(p0, p1, p2, p3))

# Upper edge of the tail, from the cut end (under the magnet) to the tip.
TOP = [((738, 394), (580, 362), (420, 330), (320, 380)),
       ((320, 380), (240, 430), (200, 600), (240, 760))]
# Lower edge, from the tip back to the cut end.
BOTTOM = [((262, 750), (240, 620), (280, 500), (340, 480)),
          ((340, 480), (440, 450), (580, 524), (738, 526))]

def path_d():
    (a, b, c, d), (_, f, g, h) = TOP
    (i, j, k, l), (_, n, o, p) = BOTTOM
    P = lambda q: f"{q[0]},{q[1]}"
    return (f"M{P(a)} C{P(b)} {P(c)} {P(d)} C{P(f)} {P(g)} {P(h)} "
            f"C246,774 266,770 {P(i)} C{P(j)} {P(k)} {P(l)} C{P(n)} {P(o)} {P(p)} Z")

def spikes(style='fill="url(#spike)" stroke="#123d22" stroke-width="5" stroke-linejoin="round"', grow=1.0):
    """Back plates along the upper edge, shrinking toward the tip."""
    out = []
    samples = []
    for seg in TOP:
        for s in range(200):
            samples.append(bez(*seg, s / 200))
    # Arc-length positions for the plates.
    lengths = [0.0]
    for p, q in zip(samples, samples[1:]):
        lengths.append(lengths[-1] + math.dist(p, q))
    total = lengths[-1]
    for frac, size in [(0.07, 60), (0.19, 54), (0.31, 47), (0.43, 40), (0.55, 33), (0.67, 26), (0.78, 20), (0.88, 15)]:
        size *= grow
        target = frac * total
        idx = next(i for i, L in enumerate(lengths) if L >= target)
        x, y = samples[idx]
        x2, y2 = samples[min(idx + 3, len(samples) - 1)]
        dx, dy = x2 - x, y2 - y
        n = math.hypot(dx, dy)
        tx, ty = dx / n, dy / n          # tangent
        nx, ny = -ty, tx                 # normal pointing out of the back
        half = size * 0.55
        base1 = (x - tx * half + nx * -6, y - ty * half + ny * -6)
        base2 = (x + tx * half + nx * -6, y + ty * half + ny * -6)
        tipp = (x + nx * size + tx * size * 0.25, y + ny * size + ty * size * 0.25)
        f = lambda p: f"{p[0]:.1f},{p[1]:.1f}"
        out.append(f'<path d="M{f(base1)} Q{f(((base1[0]+tipp[0])/2 - tx*4, (base1[1]+tipp[1])/2 - ty*4))} {f(tipp)} '
                   f'Q{f(((base2[0]+tipp[0])/2 + nx*4, (base2[1]+tipp[1])/2 + ny*4))} {f(base2)} Z" '
                   f'{style}/>')
    return "\n    ".join(out)

def disk():
    """A steel disk on the cut end, seen edge-on, flat against the plate."""
    x0, x1, cy, h = 722, 774, 460, 176
    return f'''<rect x="{x0}" y="{cy-h//2}" width="{x1-x0}" height="{h}" rx="12" fill="url(#disk)" stroke="#3a3f47" stroke-width="6"/>
    <rect x="{x0+9}" y="{cy-h//2+14}" width="7" height="{h-28}" rx="3.5" fill="#ffffff" opacity=".75"/>
    <rect x="{x1-14}" y="{cy-h//2+8}" width="5" height="{h-16}" rx="2.5" fill="#2b3038" opacity=".35"/>'''

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="186"/></clipPath>
    <radialGradient id="bg" cx="35%" cy="30%" r="85%">
      <stop offset="0" stop-color="#2a3446"/><stop offset="1" stop-color="#0d1119"/>
    </radialGradient>
    <linearGradient id="steel" x1="0" x2="1">
      <stop offset="0" stop-color="#5d6570"/><stop offset=".12" stop-color="#c9d0d8"/>
      <stop offset=".45" stop-color="#eef1f4"/><stop offset=".75" stop-color="#a7afb9"/>
      <stop offset="1" stop-color="#7b838e"/>
    </linearGradient>
    <pattern id="brush" width="1024" height="6" patternUnits="userSpaceOnUse">
      <rect width="1024" height="2" fill="#ffffff" opacity=".10"/>
    </pattern>
    <radialGradient id="rivet" cx="35%" cy="35%" r="70%">
      <stop offset="0" stop-color="#ffffff"/><stop offset=".5" stop-color="#b9c0c8"/><stop offset="1" stop-color="#5a616b"/>
    </radialGradient>
    <linearGradient id="skin" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5fd17a"/><stop offset=".55" stop-color="#2f9e52"/><stop offset="1" stop-color="#1d6b37"/>
    </linearGradient>
    <linearGradient id="spike" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#b8f06a"/><stop offset="1" stop-color="#4fb35d"/>
    </linearGradient>
    <linearGradient id="red" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ff5a4e"/><stop offset=".6" stop-color="#d4232a"/><stop offset="1" stop-color="#9c1419"/>
    </linearGradient>
    <linearGradient id="disk" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#8e96a1"/><stop offset=".3" stop-color="#e9edf1"/>
      <stop offset=".7" stop-color="#b7bec7"/><stop offset="1" stop-color="#6e7681"/>
    </linearGradient>
    <linearGradient id="pole" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#f4f6f8"/><stop offset=".5" stop-color="#b3bac3"/><stop offset="1" stop-color="#7d858f"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="14" stdDeviation="14" flood-color="#000" flood-opacity=".45"/>
    </filter>
  </defs>
  <g clip-path="url(#tile)">
    <rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>
    <!-- steel plate on the right edge -->
    <rect x="772" y="100" width="160" height="824" fill="url(#steel)"/>
    <rect x="772" y="100" width="160" height="824" fill="url(#brush)"/>
    <rect x="772" y="100" width="6" height="824" fill="#2b3038" opacity=".55"/>
    <circle cx="850" cy="232" r="17" fill="url(#rivet)" stroke="#4a5059" stroke-width="3"/>
    <circle cx="850" cy="792" r="17" fill="url(#rivet)" stroke="#4a5059" stroke-width="3"/>
    <g filter="url(#shadow)">
    {spikes()}
    <path d="{path_d()}" fill="url(#skin)" stroke="#123d22" stroke-width="7" stroke-linejoin="round"/>
    <path d="M712,512 C560,505 430,450 345,465 C292,478 262,560 258,690" fill="none" stroke="#a6e8a0" stroke-width="16" stroke-linecap="round" opacity=".45"/>
    {disk()}
    </g>
  </g>
  <rect x="100" y="100" width="824" height="824" rx="186" fill="none" stroke="#ffffff" stroke-opacity=".08" stroke-width="4"/>
</svg>
'''

# Menu bar version: a one-colour silhouette that macOS draws as a template image
# (tinted and glassy to match the menu bar). Gaps separate tail, disk and plate.
menubar = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="190 262 650 536" width="38.8" height="32">
  <defs>
    <mask id="gaps" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <rect width="1024" height="1024" fill="#fff"/>
      <rect x="700" y="0" width="26" height="1024" fill="#000"/>
    </mask>
  </defs>
  <g mask="url(#gaps)">
    {spikes('fill="#000"', grow=1.35)}
    <path d="{path_d()}" fill="#000"/>
  </g>
  <rect x="726" y="364" width="44" height="192" rx="10" fill="#000"/>
  <rect x="790" y="272" width="50" height="516" rx="14" fill="#000"/>
</svg>
'''

root = Path(__file__).resolve().parent.parent
for path, text in [(root / "assets" / "logo.svg", svg), (root / "Resources" / "menubar.svg", menubar)]:
    path.parent.mkdir(exist_ok=True)
    path.write_text(text)
    print(path)
