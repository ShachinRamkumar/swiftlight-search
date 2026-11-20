"""Generate report tables and cost estimates from completed, retained results."""
import hashlib
import json
from pathlib import Path
import statistics
from datetime import date

import numpy as np

from evaluate import METRICS, selections, summarize

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ORDER = ['P','T','I','V1','V1_raw','V2','V2_text_image','prompt_image','V2+P']
LABELS = {'P':'P: 200-character rule','T':'T: text','I':'I: image','V1':'V1: P plus image, centered',
          'V1_raw':'V1: raw-cosine max','V2':'V2: prompt, image, text','V2_text_image':'V2: text before image',
          'prompt_image':'Prompt plus image, no text','V2+P':'V2 plus P, centered'}


def metric_table(scope):
    lines = ['| Variant | nDCG@5 | Recall@1 | Recall@5 | MRR@10 |',
             '|---|---:|---:|---:|---:|---:|']
    for variant in ORDER:
        cells = []
        for metric in METRICS:
            row = scope['variants'][variant][metric]
            lo, hi = row['delta_ci95']
            cells.append(f"{row['value']:.3f}" if variant=='P' else
                         f"{row['value']:.3f}; {row['delta_vs_P']:+.3f} [{lo:+.3f}, {hi:+.3f}]")
        lines.append('| ' + LABELS[variant] + ' | ' + ' | '.join(cells) + ' |')
    return '\n'.join(lines)


def costs():
    source = REPO / 'research/neural-engine-storage/full-runtime/summary.json'
    timing = json.loads(source.read_text())
    ms = {n: timing['text_fidelity'][f'd{n}']['original_warm']['median_ms'] for n in [256,512,1024,2048]}
    vision = statistics.median(next(x['warm_seconds'] for x in timing['media']['vision'] if x['function']=='v2520'))*1000

    def text_ms(count):
        return ms[next(b for b in ms if count <= b)]

    all_rows = []
    per_subset = {}
    for path in sorted(HERE.glob('inputs-*.json')):
        inputs = json.loads(path.read_text())
        selected = selections([p['text_characters'] for p in inputs])
        values = {}
        for variant, rows in selected.items():
            page_tokens = np.zeros(len(inputs))
            page_ms = np.zeros(len(inputs))
            page_vectors = np.zeros(len(inputs))
            vision_pages = set()
            for index, kind in rows:
                count = inputs[index]['token_counts'][kind]
                page_tokens[index] += count
                page_ms[index] += text_ms(count)
                page_vectors[index] += 1
                if kind != 'T':
                    vision_pages.add(index)
            for index in vision_pages:
                page_ms[index] += vision
            values[variant] = {'mean_tokens_per_page':float(page_tokens.mean()),
                               'mean_estimated_CoreAI_ms_per_page':float(page_ms.mean()),
                               'mean_vectors_per_page':float(page_vectors.mean()),
                               'mean_vector_bytes_per_page':float(page_vectors.mean()*768*4),
                               'total_tokens':int(page_tokens.sum()), 'pages':len(inputs),
                               'vision_passes':len(vision_pages)}
        per_subset[path.stem.removeprefix('inputs-')] = values
        all_rows.append(values)
    total = sum(r['P']['pages'] for r in all_rows)
    pooled = {v:{k:sum(r[v][k]*r[v]['pages'] for r in all_rows)/total
                   for k in ['mean_tokens_per_page','mean_estimated_CoreAI_ms_per_page','mean_vectors_per_page',
                             'mean_vector_bytes_per_page']}
              for v in ORDER}
    result = {'timing_source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
              'text_bucket_median_ms':ms,'v2520_median_ms':vision,'subsets':per_subset,'pooled':pooled,
              'assumptions':['warm original CoreAI models; no host prep, OCR, compilation, or disk I/O',
                             'mixed inputs use the next existing text bucket; this is an estimate, not a mixed CoreAI measurement',
                             'V2+P shares the image encoder output when both vectors use the same image',
                             'one image vision pass per page at full budget 280, even when valid tokens are fewer']}
    (HERE/'costs.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def main():
    results = json.loads((HERE/'results.json').read_text())
    if results['status'] != 'complete':
        raise RuntimeError('cannot report an incomplete evaluation')
    values, groups = {}, []
    for name in ['energy','shift','ai','biomedical_lectures']:
        path = HERE/f'metrics-{name}.json'
        if path.exists():
            data = json.loads(path.read_text())
            groups += data['clusters']
            for v,a in data['values'].items():
                values.setdefault(v,[]).append(np.array(a))
    results['owner_like_pooled'] = summarize({v:np.concatenate(a) for v,a in values.items()},groups)
    (HERE/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    cost = costs()
    primary = results.get('merged_owner_queries',results['owner_like_pooled'])['variants']
    p, v1, v2 = (primary[v]['nDCG@5'] for v in ['P','V1','V2'])
    def effect(row):
        lo,hi=row['delta_ci95']
        return f"{row['value']:.3f}, a change of {row['delta_vs_P']*100:+.2f} percentage points [{lo*100:+.2f}, {hi*100:+.2f}]"
    if v1['delta_ci95'][0] > 0:
        answer = 'Adding a separate image vector improves retrieval for the public report and lecture queries.'
    elif v1['delta_ci95'][1] < 0:
        answer = 'Adding a separate image vector hurts retrieval for the public report and lecture queries.'
    else:
        answer = 'The public report and lecture queries do not establish a clear retrieval gain from adding a separate image vector.'
    if 'merged_corpus' in results:
        answer+=f" These queries search the combined {results['merged_corpus']['pages']:,}-page corpus."
    answer += f" P nDCG@5 is {p['value']:.3f}. V1 reaches {effect(v1)}. The image-first mixed input reaches {effect(v2)}."
    answer += ' These intervals compare the same queries and source clusters. The private-file result and Core AI replay remain necessary before changing the app default.'
    resource_path=HERE/'resource.json'
    resource=json.loads(resource_path.read_text()) if resource_path.exists() else {}
    resource_summary=(f"The conservative download ledger is {resource['download_upper_bound_bytes']/1e9:.3f} GB including the 0.500 GB reserve. "
                      if 'download_upper_bound_bytes' in resource else 'The final resource ledger has not been collected. ')
    resource_summary+=(f"Final free disk after owned scratch cleanup is {resource['final_free_bytes']/1024**3:.2f} GiB. "
                       if 'final_free_bytes' in resource else 'Final cache cleanup has not yet been recorded. ')
    resource_summary+=('The October attempt was lost during a reboot. The November restart uses persistent storage and a new 4 GB reacquisition budget. '
                       'The benchmark uses MPS and CPU Tesseract. It does not call Core AI or the Neural Engine.')
    lines = ['# Public document input study', '',
             f'{date.today().isoformat()}. This is an OCR-based public benchmark. Production Core AI parity is pending the separate replay.', '',
             '## Answer', '',
             answer, '',
             '## Accuracy', '',
             'Each nonbaseline cell gives the score, its paired difference from P, and the bootstrap 95% interval for that difference. '
             'Scores and differences are fractions. Multiply by 100 for percentage points.', '',
             'P follows the requested 200-character rule using the available OCR text. It is a proxy for production, '
             'which normally uses a PDF text layer. All retrieval runs use unfiltered rankings; the gates are evaluated separately.', '',
             '### Subsets', '',
             '| Subset | Pages | Original pages | Queries retained | Source clusters | P text pages |',
             '|---|---:|---:|---:|---:|---:|']
    for name,s in results['subsets'].items():
        lines.append(f"| {name} | {s['pages']} | {s['source_pages']} | {s['queries']} | {s['clusters']} | {s['production_text_pages']} |")
    scopes=[]
    if 'merged_corpus' in results:
        scopes += [('Reports and lectures, merged corpus',results['merged_owner_queries']),
                   ('All queries, merged corpus',results['merged_corpus'])]
    scopes += [('Reports and lectures, within-subset aggregate',results['owner_like_pooled']),
               ('All queries, within-subset aggregate',results['pooled'])]
    for name,s in scopes:
        lines += ['',f'### {name}', '', f"{s['queries']} queries across {s['clusters']} source clusters.", '',
                  '| Input variant | nDCG@5 with absolute 95% CI | Difference from P with 95% CI |',
                  '|---|---:|---:|']
        for v in ORDER:
            row=s['variants'][v]['nDCG@5']
            lo,hi=row['value_ci95'];dlo,dhi=row['delta_ci95']
            lines.append(f"| {LABELS[v]} | {row['value']:.3f} [{lo:.3f}, {hi:.3f}] | {row['delta_vs_P']:+.3f} [{dlo:+.3f}, {dhi:+.3f}] |")
        lines += ['',metric_table(s)]
    lines += ['', 'The merged-corpus analysis ranks against all 3000 selected pages together and recalculates meaning scores across that corpus. '
              'Exact duplicate queries across subsets share the union of annotated positives. The within-subset aggregates instead combine independent '
              '500-page retrieval results, weighted by query count. Report and lecture queries come from energy, Shift reports, AI, and biomedical lectures. '
              'ArXiv figures and infographics are included in the all-query results and compete as pages in the merged corpus.', '']
    for name,s in results['subsets'].items():
        lines += [f'### {name}', '',metric_table(s),'',f"Text: {s['text_source']}.", '', f"Sampling: {s['sampling']}.", '']
    lines += ['## No-answer check', '',
              'These queries are run against a different subset with no supplied cross-subset relevance labels. '
              'Counts are apparent false accepts, not proven false-positive rates. A cross-domain question could still be answerable.', '',
              '| Query subset to page subset | Queries | Variant | Top Z >= 4.5 | Rate |', '|---|---:|---|---:|---:|']
    for block in results['no_answer']:
        for v, counts in block['counts'].items():
            n=counts['4.5']
            lines.append(f"| {block['query_subset']} to {block['corpus_subset']} | {block['queries']} | {LABELS[v]} | {n} | {n/block['queries']:.1%} |")
    lines += ['', 'The JSON also retains counts at CONFIRMED_GATE 2.5 and NEAR_GATE 3.0. V1 raw cosine has no comparable Z gate. '
              'Applying `meaning()` to those same rows produces V1 centered, whose gate count is reported.', '',
              '## Token and on-device cost estimates', '',
              'Costs use the measured warm Core AI medians in `research/neural-engine-storage/full-runtime/summary.json` '
              'and the bucket descriptions in `research/combined-footprint/REPORT.md`. No Core AI execution was performed for this study. '
              'The model-only estimate adds one vision call and the relevant text bucket for each vector. It excludes host preparation, OCR, '
              'tokenization, model repair, cold starts, and I/O.', '',
              '| Variant | Mean total tokens per page | Estimated warm ms per page | Vectors per page | Float32 vector bytes per page |',
              '|---|---:|---:|---:|---:|']
    for v in ORDER:
        c=cost['pooled'][v]
        lines.append(f"| {LABELS[v]} | {c['mean_tokens_per_page']:.1f} | {c['mean_estimated_CoreAI_ms_per_page']:.1f} | {c['mean_vectors_per_page']:.2f} | {c['mean_vector_bytes_per_page']:.0f} |")
    lines += ['', f"The fixed 280-budget vision pass costs {cost['v2520_median_ms']:.2f} ms. Text bucket medians are " +
              ', '.join(f"d{k} {v:.2f} ms" for k,v in cost['text_bucket_median_ms'].items()) + '.', '',
              'V2 cost assumes the current text model can consume the manually composed mixed sequence in its next bucket. '
              'That path is unimplemented in production. V2+P assumes the image encoder result can be reused, and is optimistic if the implementation repeats it. '
              '`costs.json` gives per-subset estimates and token totals.', '',
              '## Method', '',
              'The reference is the original `google/embeddinggemma-2` checkpoint at revision '
              '`914f7f89142e33e77833254d9c9b90c3cef7303b`, loaded with audio disabled, FP32 activations, and PyTorch MPS. '
              'Package versions are pinned in `requirements-lock.txt`. The weights and tokenizer hashes are checked by `acquire.py`. '
              'The reference model uses bidirectional attention, a 512-to-768 projection, mean pooling over actual sequence positions, '
              'and final L2 normalization. Text calls pad to 128, 256, 512, 1024, or 2048 positions to bound MPS graph shapes. '
              'Padding keys are masked and padded output positions are excluded from pooling. The native unpadded path supplies the parity comparison. '
              'No causal splitting or averaging of separate text and image embeddings is used for V2.', '',
              'Query inputs are `task: search result | query: {q}`, limited to 512 tokens including BOS and EOS. '
              'Document text inputs are `title: {title or none} | text: {text}`, limited to 2048 tokens. '
              'The first 4000 extended grapheme clusters of OCR text enter the document prompt. Dataset filenames supply fallback titles because original PDF metadata is absent. '
              'Answers, multiple-choice options, generated prompts, and document summaries never enter document embeddings.', '',
              'Page rasters fit within 1400 by 1400 without upscaling. The fixed-point production bicubic algorithm then resizes them '
              'to multiples of 48 with at most 2520 patches. Row-major 16-pixel patches have x/y positions and 3-by-3 pooling. '
              'The exact image sequence is `[2,255999] + [258880]*n + [258882,1]`. The ceiling is 280 soft tokens; actual n can be smaller.', '',
              'V1 takes the maximum over the page\'s vectors after the exact production per-modality centering and global population standard deviation, '
              'floored at 0.02. Groups under 20 vectors use the global mean. V1 raw takes the raw-cosine maximum instead. '
              'The scale includes every vector in the evaluated subset. V2+P assigns mixed inputs a separate centering group. '
              'This grouping is a research choice because production has no mixed-input tag.', '',
              'V2 uses BOS, the separately tokenized `title: T | text:` prefix, BOI, image soft tokens, EOI, '
              'a space followed by page text, and EOS. The alternate ordering puts the complete document prompt before the image block. '
              'Prompt-plus-image omits page text. The complete mixed sequence is capped at 2048 tokens by trimming only text. '
              'Exact mixed IDs and truncation counts are retained in the fixtures and input statistics.', '',
              'Pages and relevance labels are fixed across variants. Page sampling uses seed 20261027. '
              'Queries are retained only if their entire annotated positive set remains in the sampled corpus. '
              'Repeated exact questions share the union of their positive pages. V2 datasets retain all positives when those fit within 500 pages, '
              'then fill the corpus with random distractors. This changes retrieval difficulty from the full official benchmark. '
              'No query, page, or variant is selected based on model results.', '',
              'nDCG uses graded gains `2^relevance - 1`. Recall divides by all annotated positives for a query. '
              'MRR@10 uses the first positive within ten. Ties use stable page-ID order. The paired percentile bootstrap '
              'uses 5000 source-cluster resamples and the same sampled queries for each variant. '
              'A query with positives in several sources belongs to the lexicographically first positive page\'s source. '
              'Paper IDs cluster ArXiv figures, and image IDs cluster infographics. '
              'These are exploratory, unadjusted 95% intervals across several variants. Subsets with few source documents have weak uncertainty estimates. '
              'The owner-like aggregate and subset consistency matter more than a single winning cell.', '',
              '### Parity', '',
              'The eight text fixtures compare manual input embeddings with the model\'s native input-ID path. '
              'Two image fixtures and one mixed fixture compare manual soft-token replacement with the model\'s native multimodal forward. '
              'The independent HF image processor agrees on patch positions, with at most one 8-bit level of resize difference. '
              'The benchmark uses the production fixed-point resize rather than replacing it with the HF processor. '
              '`parity.json` records all 11 PyTorch manual-vs-HF-native numerical checks. Third-party dataset page rasters are not committed to Git; Core AI on-device parity remains pending external replay.', '',
              '## Deviations and limits', '',
              'The public data provides rasters and OCR rather than original PDF text layers. P therefore measures a text-availability proxy. '
              'Production also suppresses mostly-digit text and handles garbled PDF extraction specially; these branches cannot be replayed from these datasets. '
              'ArXivQA contains figures rather than complete PDF pages. Dataset image compression, rasterization, and fallback filenames differ from local PDFKit rendering. '
              'The public benchmark includes synthetic questions and may overlap model training data. '
              'It supports a comparative public result, not a guarantee about the owner\'s files.', '',
              'Reference computation uses FP32 and the original checkpoint, rather than Core AI\'s prepared FP16 tensors or the Q8 GGUF. '
              'The parity checks compare two HF/PyTorch paths. They do not prove production numerical parity. '
              'The standalone pure numerical checks are recorded in `checks.json`; the earlier-script review is in `AUDIT.md`.', '',
              '## Resource use and reproduction', '',
              resource_summary, '',
              'All downloaded assets, OCR scratch, embeddings, virtual environment, and redirected HF cache live under '
              '`~/.swiftlight-research/public-bench/` during the run. They survive a reboot and are deleted after preserving completed results. '
              'The guarded downloader refuses an allocation that would cross 14 GiB free or 4,000,000,000 cumulative downloaded bytes in this reacquired run. '
              'A conservative 500 MB reserve covers pip and preliminary source inspection. Transfers, including retry bodies, consume the remaining allowance. '
              'No dataset, weight, checkpoint, or individual file over 5 MB is committed.', '',
              '```sh',
              'TASK_TMP="$HOME/.swiftlight-research/public-bench"',
              'python3.13 -m venv "$TASK_TMP/venv"',
              'HF_HOME="$TASK_TMP/hf" "$TASK_TMP/venv/bin/pip" install --no-cache-dir -r research/document-inputs-public/requirements-lock.txt',
              'PYTHONDONTWRITEBYTECODE=1 "$TASK_TMP/venv/bin/python" research/document-inputs-public/acquire.py',
              'PYTHONDONTWRITEBYTECODE=1 "$TASK_TMP/venv/bin/python" research/document-inputs-public/checks.py',
              'PYTHONDONTWRITEBYTECODE=1 "$TASK_TMP/venv/bin/python" research/document-inputs-public/run.py',
              'PYTHONDONTWRITEBYTECODE=1 "$TASK_TMP/venv/bin/python" research/document-inputs-public/pool.py',
              'PYTHONDONTWRITEBYTECODE=1 "$TASK_TMP/venv/bin/python" research/document-inputs-public/report.py',
              '```', '',
              'Read the available disk space before creating the environment. Package installation itself is outside the guarded downloader. '
              'Use the committed input and metric JSON files to recompute costs and intervals without downloading data.', '',
              '## Sources', '',
              '- [Original model card and input guidance](https://huggingface.co/google/embeddinggemma-2/blob/914f7f89142e33e77833254d9c9b90c3cef7303b/README.md)',
              '- [HF model implementation](https://github.com/huggingface/transformers/blob/144ecf007b8b4f2910da104c84a79801db6985a6/src/transformers/models/embedding_gemma2/modeling_embedding_gemma2.py)',
              '- [ViDoRe benchmark implementation](https://github.com/illuin-tech/vidore-benchmark)',
              '- Dataset identities and immutable revisions are recorded per subset in `results.json` and `subsets.py`.',
              '- Production source review and additional references are in `AUDIT.md`.']
    (HERE/'REPORT.md').write_text('\n'.join(lines)+'\n')


if __name__=='__main__':
    main()
