# python3 benchmark/rd_table.py benchmark/sweep/scores.txt
# File size each encoder needs to reach a given SSIMULACRA2 score (linear interpolation).
import sys, collections
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    p = l.split(); img, enc, q = p[4].rsplit('.', 1)[0].split('__')
    d[(img, enc)].append((float(p[3]), float(p[0]), int(q)))
def at(pts, t):
    pts = sorted(pts)
    for (s0, k0, _), (s1, k1, _) in zip(pts, pts[1:]):
        if s0 <= t <= s1: return k0 + (k1 - k0) * (t - s0) / (s1 - s0)
for img in ['photo', 'horizon']:
    print(f"\n{img}: KB needed for score 70 / 80 / 85      (q:score)")
    for enc in ['rust-balanced', 'rust-fast', 'rust-webp', 'apple-imageio', 'ios-fic', 'android-fic', 'dart-image']:
        if (img, enc) not in d: continue
        cells = "".join(f"{(f'{x:.0f}' if x else '-'):>8}" for x in [at(d[(img, enc)], t) for t in (70, 80, 85)])
        print(f"  {enc:14}{cells}    " + " ".join(f"{q}:{s:.0f}" for s, k, q in sorted(d[(img, enc)], key=lambda x: x[2])))
