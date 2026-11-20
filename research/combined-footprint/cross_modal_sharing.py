"""Read-only: do text, vision and audio share any identical weight blobs?"""
import json
from pathlib import Path
d = json.loads((Path(__file__).resolve().parents[1] / 'neural-engine-storage/lossless-resource-statistics.json').read_text())
sets = {a['asset']: {r['sha256']: r['resource_bytes'] for r in a['resources']} for a in d['assets']}
names = list(sets)
out = {}
for i, a in enumerate(names):
    for b in names[i + 1:]:
        common = set(sets[a]) & set(sets[b])
        out[f'{a} & {b}'] = dict(shared_blobs=len(common), shared_bytes=sum(sets[a][h] for h in common))
for a in names:
    out[a] = dict(blobs=len(sets[a]), unique_bytes=sum(sets[a].values()))
print(json.dumps(out, indent=1))
Path('cross-modal-sharing.json').write_text(json.dumps(out, indent=1))
