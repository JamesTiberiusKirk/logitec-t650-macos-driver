#!/usr/bin/env python3
"""Split a capture into gesture segments on idle gaps and summarise each.

Idle produces zero reports on this device (verified: captures/10-idle-baseline),
so any inter-report gap above the threshold is an unambiguous gesture boundary.

Usage: segment.py <capture.txt> [gap_ms]
"""
import sys, re
from collections import Counter

def parse(path):
    for line in open(path):
        if line.startswith("#"): continue
        m = re.match(r"\s*([\d.]+)\s+([\d.]+)\s+((?:[0-9a-f]{2} )+[0-9a-f]{2})", line)
        if m:
            yield float(m.group(1)), float(m.group(2)), bytes.fromhex(m.group(3).replace(" ", ""))

def decode(p):
    f = lambda d: dict(ty=d[0] >> 6, st=d[2] >> 6, x=((d[0] & 0x3f) << 8) | d[1],
                       y=((d[2] & 0x3f) << 8) | d[3], z=d[4], area=d[5], fid=d[6] >> 4)
    return dict(ts=(p[0] << 8) | p[1], eof=p[8] & 1, spur=(p[8] >> 1) & 1,
                btn=(p[8] >> 2) & 1, n=p[15] & 0x0f, fingers=[f(p[2:9]), f(p[9:16])])

def main():
    path = sys.argv[1]
    gap = float(sys.argv[2]) if len(sys.argv) > 2 else 1500.0
    segs, cur = [], []
    for t, dt, data in parse(path):
        if cur and dt > gap:
            segs.append(cur); cur = []
        cur.append((t, dt, data))
    if cur: segs.append(cur)

    print(f"{path}: {sum(len(s) for s in segs)} reports in {len(segs)} segments "
          f"(boundary = gap > {gap:.0f} ms)\n")
    for i, s in enumerate(segs, 1):
        raws = [decode(d[4:]) for _, _, d in s if d[0] == 0x11 and d[2] == 0x0f and d[3] == 0x00]
        others = Counter(d[0] for _, _, d in s if not (d[0] == 0x11 and d[2] == 0x0f))
        dur = s[-1][0] - s[0][0]
        if not raws:
            print(f"-- segment {i}: {len(s)} reports, {dur:.0f} ms, no raw-XY "
                  f"(report ids: {dict(others)})"); continue
        maxn = max(r["n"] for r in raws)
        ids = sorted({g["fid"] for r in raws for g in r["fingers"] if g["fid"]})
        xs = [g["x"] for r in raws for g in r["fingers"] if g["fid"] and g["st"]]
        ys = [g["y"] for r in raws for g in r["fingers"] if g["fid"] and g["st"]]
        areas = [g["area"] for r in raws for g in r["fingers"] if g["fid"] and g["st"]]
        # reports per frame: a frame ends at eof=1
        frames, cnt = [], 0
        for r in raws:
            cnt += 1
            if r["eof"]: frames.append(cnt); cnt = 0
        fc = Counter(frames)
        dts = [dt for _, dt, _ in s[1:]]
        print(f"-- segment {i}: {len(s)} reports, {dur:.0f} ms")
        print(f"     finger_count max={maxn}   finger_ids seen={ids}")
        print(f"     x {min(xs)}..{max(xs)}   y {min(ys)}..{max(ys)}   area {min(areas)}..{max(areas)}")
        print(f"     button set in {sum(r['btn'] for r in raws)} reports; "
              f"spurious in {sum(r['spur'] for r in raws)}; "
              f"lift (status=0) reports: {sum(1 for r in raws for g in r['fingers'] if g['fid'] and not g['st'])}")
        print(f"     reports/frame: {dict(sorted(fc.items()))}   "
              f"dt ms: min={min(dts):.1f} med={sorted(dts)[len(dts)//2]:.1f} max={max(dts):.1f}")
        if raws[0]['ts'] is not None and len(raws) > 1:
            dts_hw = (raws[-1]['ts'] - raws[0]['ts']) % 65536
            print(f"     hw timestamp delta={dts_hw} over {dur:.0f} ms wall -> {dts_hw/dur if dur else 0:.3f} units/ms")
        if others: print(f"     non-raw reports: {dict(others)}")
        print()

if __name__ == "__main__":
    main()
