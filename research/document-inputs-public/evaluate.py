"""Paired retrieval metrics, production meaning(), fusion and clustered bootstrap."""
import numpy as np

METRICS = ['nDCG@5', 'Recall@1', 'Recall@5', 'MRR@10']


def meaning(scores, modality):
    scores = np.asarray(scores, dtype=np.float64)
    modality = np.asarray(modality)
    means = np.full(4, scores.mean())
    for m in range(4):
        if (modality == m).sum() >= 20:
            means[m] = scores[modality == m].mean()
    centered = scores - means[modality]
    return (centered - centered.mean()) / max(centered.std(ddof=0), 0.02)


def score(query, vectors, selected, modalities, n_pages, raw=False):
    page, which = zip(*selected)
    cosine = np.array([vectors[w][p] @ query for p, w in selected])
    values = cosine if raw else meaning(cosine, [modalities[w] for w in which])
    result = np.full(n_pages, -np.inf)
    np.maximum.at(result, np.array(page), values)
    return result


def metric(scores, relevance):
    order = np.argsort(-scores, kind='stable')[:10]
    grades = relevance[order]
    gains = np.exp2(grades[:5]) - 1
    dcg = (gains / np.log2(np.arange(len(gains)) + 2)).sum()
    ideal = np.sort(relevance)[::-1][:5]
    idcg = ((np.exp2(ideal) - 1) / np.log2(np.arange(len(ideal)) + 2)).sum()
    relevant = relevance > 0
    rank = np.flatnonzero(grades > 0)
    return np.array([dcg / idcg, relevant[order[:1]].sum() / relevant.sum(),
                     relevant[order[:5]].sum() / relevant.sum(), 1 / (rank[0] + 1) if len(rank) else 0])


def summarize(values, clusters, seed=20261027, repetitions=5000):
    """Resample source-document clusters, keeping paired variants and all their queries together."""
    clusters = np.asarray(clusters)
    unique = sorted(set(clusters))
    indices = [np.flatnonzero(clusters == c) for c in unique]
    rng = np.random.default_rng(seed)
    sample_indices = [np.concatenate([indices[i] for i in rng.integers(0, len(indices), len(indices))])
                      for _ in range(repetitions)]
    baseline = values['P']
    base_boot=np.array([baseline[i].mean(axis=0) for i in sample_indices])
    result = {}
    for variant, data in values.items():
        delta = data - baseline
        boot = np.array([delta[i].mean(axis=0) for i in sample_indices])
        lo, hi = np.quantile(boot, [0.025, 0.975], axis=0)
        value_lo,value_hi=np.quantile(boot+base_boot,[0.025,0.975],axis=0)
        result[variant] = {m: {'value': float(data[:, j].mean()), 'delta_vs_P': float(delta[:, j].mean()),
                               'delta_ci95': [float(lo[j]), float(hi[j])],
                               'value_ci95':[float(value_lo[j]),float(value_hi[j])]}
                           for j, m in enumerate(METRICS)}
    return {'queries': len(clusters), 'clusters': len(unique), 'bootstrap_repetitions': repetitions,
            'bootstrap_unit': 'source document of lexicographically first positive page', 'variants': result}


def selections(text_lengths):
    p = [(i, 'T' if n >= 200 else 'I') for i, n in enumerate(text_lengths)]
    out = {v: [(i, v) for i in range(len(p))] for v in ['T', 'I', 'V2', 'V2_text_image', 'prompt_image']}
    out['P'] = p
    out['V1'] = p + [(i, 'I') for i, n in enumerate(text_lengths) if n >= 200]
    out['V1_raw'] = out['V1']
    out['V2+P'] = p + out['V2']
    return out


MODALITIES = {'T': 0, 'I': 1, 'V2': 2, 'V2_text_image': 2, 'prompt_image': 2}
