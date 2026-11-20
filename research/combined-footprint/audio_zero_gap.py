"""Read-only: are audio zeros magnitude pruning (gap near zero) or FP16 underflow (subnormals present)?"""
import json, mmap, sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'model-storage/weight-sharing'))
from resources import inventory
src = Path.home() / 'Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1/audio.aimodel/main.mlirb'
with open(src, 'rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
    inv = inventory(m)
mm = np.memmap(src, dtype=np.uint8, mode='r')
rows = []
for r in inv['resources']:
    if r['bytes'] < 1 << 20: continue
    w = mm[r['offset']:r['offset'] + r['bytes']].view(np.float16).astype(np.float32)
    a = np.abs(w); nz = a[a > 0]
    zf = 1 - nz.size / a.size
    if zf < 0.05: continue
    q = np.quantile(nz, [0, 0.001, 0.01, 0.5, 0.99])
    sub = float((nz < 6.1035e-5).mean())
    # fraction of nonzeros below 2x the smallest nonzero: a hole indicates pruning
    rows.append(dict(key=r['key'], zero=zf, min_nz=float(q[0]), p001=float(q[1]), p01=float(q[2]), median=float(q[3]), p99=float(q[4]), subnormal_share=sub,
                     zero_over_nz_below_median=zf / max(1e-9, (1 - zf) * 0.5)))
for x in rows[:12]:
    print(x['key'][-12:], f"zero={x['zero']:.3f} min_nz={x['min_nz']:.2e} p0.1%={x['p001']:.2e} p1%={x['p01']:.2e} median={x['median']:.2e} p99={x['p99']:.2e} subnormal={x['subnormal_share']:.4f}")
Path('audio-zero-gap.json').write_text(json.dumps(rows, indent=1))
print(len(rows), 'heavy resources; median of min_nz', np.median([x['min_nz'] for x in rows]), 'median p1%', np.median([x['p01'] for x in rows]))
