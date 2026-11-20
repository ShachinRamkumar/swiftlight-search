"""Read-only: where are the audio encoder's exact-zero FP16 weights, and are they structured?"""
import json, mmap, sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'model-storage/weight-sharing'))
from resources import inventory

src = Path.home() / 'Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1/audio.aimodel/main.mlirb'
out = []
with open(src, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
    inv = inventory(m)
mm = np.memmap(src, dtype=np.uint8, mode='r')
if True:
    for r in inv['resources']:
        if r['bytes'] < 4096: continue
        w = mm[r['offset']:r['offset'] + r['bytes']].view(np.uint16)
        z = (w & 0x7FFF) == 0
        frac = float(z.mean())
        if frac < 0.05:
            out.append(dict(key=r['key'], bytes=r['bytes'], zero=frac)); continue
        # zero-run structure
        d = np.diff(np.concatenate(([0], z.view(np.int8), [0])))
        starts = np.flatnonzero(d == 1); ends = np.flatnonzero(d == -1)
        runs = ends - starts
        vals, cnts = np.unique(runs, return_counts=True)
        top = sorted(zip(cnts.tolist(), vals.tolist()), reverse=True)[:5]
        nz = ~z
        d2 = np.diff(np.concatenate(([0], nz.view(np.int8), [0])))
        nruns = np.flatnonzero(d2 == -1) - np.flatnonzero(d2 == 1)
        nv, nc = np.unique(nruns, return_counts=True)
        ntop = sorted(zip(nc.tolist(), nv.tolist()), reverse=True)[:5]
        out.append(dict(key=r['key'], bytes=r['bytes'], zero=frac, zero_runs=len(runs),
                        top_zero_run_lengths=top, top_nonzero_run_lengths=ntop))
total = sum(o['bytes'] for o in out)
zbytes = sum(o['bytes'] * o['zero'] for o in out)
heavy = [o for o in out if o['zero'] >= 0.05]
print(json.dumps(dict(resources=len(out), resource_bytes=total, zero_bytes=int(zbytes),
                      heavy_count=len(heavy), heavy_bytes=sum(o['bytes'] for o in heavy),
                      heavy_zero_bytes=int(sum(o['bytes'] * o['zero'] for o in heavy))), indent=1))
for o in heavy[:40]:
    print(o['key'][:60], o['bytes'], round(o['zero'], 4), o['top_zero_run_lengths'][:3], o['top_nonzero_run_lengths'][:3])
Path('audio-zero-structure.json').write_text(json.dumps(out, indent=1))
