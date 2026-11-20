"""Small numerical invariants for the study's scoring and public input preparation."""
import json
import math
import numpy as np

from eg2ref import image_ids, page_text, prepare_image, resize, target_size
from evaluate import meaning, metric, selections, summarize


def main():
    # A small group uses the global mean, then all rows determine the population deviation.
    scores = np.array([0.1] * 20 + [0.3] * 20 + [0.2, 0.8])
    groups = [0] * 20 + [1] * 20 + [2] * 2
    raw = scores.tolist()
    overall = sum(raw) / len(raw)
    centered = [s - (0.1 if m == 0 else 0.3 if m == 1 else overall) for s, m in zip(raw, groups)]
    mean = sum(centered) / len(centered)
    std = max(math.sqrt(sum((v-mean)**2 for v in centered) / len(centered)), 0.02)
    expected = [(v-mean)/std for v in centered]
    np.testing.assert_allclose(meaning(scores, groups), expected, atol=1e-13)
    np.testing.assert_allclose(meaning([0.5, 0.5], [0, 1]), [0, 0])
    # Actual recall, including the denominator for multiple positive pages.
    np.testing.assert_allclose(metric(np.arange(6)[::-1], np.array([2,0,1,0,0,0])),
                               [(3 + 1/math.log2(4))/(3 + 1/math.log2(3)), 0.5, 1, 1])
    np.testing.assert_allclose(metric(np.arange(12), np.array([1]+[0]*11)), [0,0,0,0])
    assert selections([199,200])['V1'] == [(0,'I'),(1,'T'),(1,'I')]
    identical = np.array([[1,1,1,1],[0,0,0,0]], dtype=float)
    stats = summarize({'P':identical, 'V1':identical}, ['a','b'], repetitions=100)
    assert all(v['delta_ci95'] == [0,0] for v in stats['variants']['V1'].values())
    shapes = []
    for h,w in [(1400,1000),(1000,1400),(1,5000),(5000,1),(100,100)]:
        th,tw = target_size(h,w,280)
        assert th%48 == tw%48 == 0 and th*tw <= 2520*256
        p,positions,n,resized = prepare_image(np.zeros((h,w,3),dtype=np.uint8))
        assert p.shape == (1,2520,768) and positions.shape == (1,2520,2)
        assert n == th*tw//2304
        ids = image_ids(n)
        assert ids == [2,255999] + [258880]*n + [258882,1]
        shapes.append({'source':[h,w], 'target':[th,tw], 'soft_tokens':n})
    # Fixed-point interpolation preserves a constant image through both passes.
    np.testing.assert_array_equal(resize(np.full((17,23,3),127,dtype=np.uint8),48,96),
                                   np.full((48,96,3),127,dtype=np.uint8))
    assert page_text('e\u0301'*4001) == 'e\u0301'*4000
    print(json.dumps({'status':'passed','checks':['scalar meaning parity','population deviation floor',
                      'graded nDCG','multi-positive recall','rank-10 cutoff','V1 selection',
                      'paired bootstrap identity','image layout','fixed-point constant preservation','grapheme truncation'],
                      'image_shapes':shapes},indent=2))


if __name__ == '__main__':
    main()
