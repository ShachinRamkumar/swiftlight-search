"""Read-only: are the shipped RoPE tables prefixes of each other, and can they be regenerated bit-exactly?"""
import hashlib, itertools, json
from pathlib import Path
import numpy as np
root = Path.home() / 'Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1/rope-tables'
hashes = json.loads((root / 'sha256.json').read_text())
def load(n, kind, fn):
    a = np.fromfile(root / f'{n}-{kind}_{fn}.f16', dtype=np.float16)
    return a.reshape(-1, n).T  # stored channel-major: (dims, positions)
out = {'prefix': {}, 'formula': {}}
for kind in ('global', 'local'):
    for fn in ('cos', 'sin'):
        big = load(2048, kind, fn)
        out['prefix'][f'{kind}_{fn}'] = {n: bool(np.array_equal(load(n, kind, fn), big[:n])) for n in (32, 64, 128, 256, 512, 1024)}
    big_c, big_s = load(2048, kind, 'cos'), load(2048, kind, 'sin')
    d = big_c.shape[1]
    best = None
    for theta, rot, layout, prec, scale in itertools.product((1e4, 1e6), (d, d // 2, d // 4), ('concat', 'interleave'), ('f32', 'f64', 'f32cos64'), (1.0,)):
        ft = np.float64 if prec == 'f64' else np.float32
        trig = np.float64 if prec != 'f32' else np.float32
        half = rot // 2
        inv = (1.0 / (ft(theta) ** (np.arange(0, rot, 2, dtype=ft) / ft(rot)))).astype(ft)
        if scale != 1.0: inv = inv / ft(scale)
        pos = np.arange(2048, dtype=ft)
        f = np.outer(pos, inv).astype(ft)
        # partial rotary: the remaining frequencies are zero (cos=1, sin=0)
        full = np.zeros((2048, d // 2), ft); full[:, :half] = f
        emb = np.concatenate([full, full], 1) if layout == 'concat' else np.repeat(full, 2, 1)
        c, s = np.cos(emb.astype(trig)).astype(np.float16), np.sin(emb.astype(trig)).astype(np.float16)
        m = float(((c == big_c).mean() + (s == big_s).mean()) / 2)
        if best is None or m > best[0]:
            best = (m, dict(theta=theta, rotary_dims=rot, layout=layout, precision=prec, scale=scale,
                            exact_cos=bool(np.array_equal(c, big_c)), exact_sin=bool(np.array_equal(s, big_s)),
                            max_abs_diff=float(max(np.abs(c.astype(np.float32) - big_c).max(), np.abs(s.astype(np.float32) - big_s).max()))))
    out['formula'][kind] = dict(match_fraction=best[0], **best[1], dims=d)
    print(kind, out['formula'][kind], flush=True)
print(json.dumps(out['prefix']))
Path('rope-regenerate.json').write_text(json.dumps(out, indent=1))
