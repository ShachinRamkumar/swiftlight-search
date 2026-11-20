"""Verify committed public benchmark outputs and numerical parity artifacts."""
import argparse
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
METRICS = ('nDCG@5', 'Recall@1', 'Recall@5', 'MRR@10')


def _mean(values):
    return sum(values) / len(values)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results-only', action='store_true')
    args = parser.parse_args()

    result = json.loads((HERE / 'results.json').read_text())
    if args.results_only:
        assert result['status'] in ('complete', 'running'), result['status']
    else:
        assert result['status'] == 'complete', result['status']

    subsets = result['subsets']
    assert subsets, 'expected at least one completed subset'
    pooled_rows = {}
    checkpoint_norm_error = {}

    for name, scope in subsets.items():
        per_query = json.loads((HERE / f'metrics-{name}.json').read_text())
        n = len(per_query['clusters'])
        assert n == scope['queries']
        assert len(set(per_query['clusters'])) == scope['clusters']
        for variant, rows in per_query['values'].items():
            assert len(rows) == n
            for row in rows:
                assert len(row) == len(METRICS)
                for value in row:
                    assert math.isfinite(value) and 0.0 <= value <= 1.0 + 1e-12
            pooled_rows.setdefault(variant, []).extend(rows)
            for j, metric in enumerate(METRICS):
                col = [row[j] for row in rows]
                stats = scope['variants'][variant][metric]
                assert abs(stats['value'] - _mean(col)) < 1e-12
                expected_delta = stats['value'] - scope['variants']['P'][metric]['value']
                assert abs(stats['delta_vs_P'] - expected_delta) < 1e-12
                lo, hi = stats['delta_ci95']
                assert -1.0 - 1e-12 <= lo <= hi <= 1.0 + 1e-12

        if not args.results_only:
            import numpy as np
            from guard import ROOT
            cache = np.load(ROOT / name / 'embeddings.npz')
            norms = {}
            for key in ['T', 'I', 'V2', 'V2_text_image', 'prompt_image', 'queries']:
                v = cache[key]
                expected = n if key == 'queries' else scope['pages']
                assert v.shape == (expected, 768) and np.isfinite(v).all()
                error = float(np.max(np.abs(np.linalg.norm(v, axis=1) - 1)))
                assert error < 1e-5
                norms[key] = error
            checkpoint_norm_error[name] = norms

    if 'pooled' in result:
        assert result['pooled']['queries'] == sum(s['queries'] for s in subsets.values())
        for variant, rows in pooled_rows.items():
            for j, metric in enumerate(METRICS):
                col = [row[j] for row in rows]
                assert abs(_mean(col) - result['pooled']['variants'][variant][metric]['value']) < 1e-12

    parity = json.loads((HERE / 'parity.json').read_text())
    checks = parity['checks']
    kinds = {k: sum(c['kind'] == k for c in checks) for k in ('query', 'document', 'image', 'mixed')}
    assert kinds == {'query': 5, 'document': 3, 'image': 2, 'mixed': 1}
    for check in checks:
        cos = check['cosine_manual_vs_native']
        assert math.isfinite(cos) and 0.999999 <= cos <= 1.0 + 1e-9

    for p in HERE.rglob('*'):
        if p.is_file():
            assert p.stat().st_size <= 5_000_000, str(p)
            assert p.suffix not in ('.npz', '.parquet', '.gguf', '.safetensors', '.png'), str(p)

    output = {
        'status': 'passed',
        'subsets': len(subsets),
        'queries': sum(s['queries'] for s in subsets.values()),
        'pages': sum(s['pages'] for s in subsets.values()),
        'parity_checks': kinds,
        'min_parity_cosine': min(c['cosine_manual_vs_native'] for c in checks),
        'checkpoint_norm_error': checkpoint_norm_error,
        'results_only': args.results_only,
        'checks': [
            'per-query metric means',
            'paired differences vs P',
            'confidence interval bounds',
            'PyTorch manual-vs-native parity summary',
            'no large weights or third-party raster fixtures in deliverables',
        ],
    }
    if not args.results_only:
        (HERE / 'verification.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    main()
