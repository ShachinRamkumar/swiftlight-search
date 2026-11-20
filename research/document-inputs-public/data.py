"""Read pinned ViDoRe viewer rows; sample pages independently of relevance labels."""
import hashlib
import ast
import json
from pathlib import Path
import random
from urllib.parse import urlencode, urlparse

from guard import ROOT, get_json
from subsets import SEED, SUBSETS
from durable import save_json


def rows(dataset, revision, config='default'):
    out = []
    offset = 0
    while True:
        params = urlencode(dict(dataset=dataset, config=config, split='test', offset=offset, length=100))
        batch_cache = ROOT / 'viewer' / (hashlib.sha256(params.encode()).hexdigest() + '.json')
        if batch_cache.exists():
            reply = json.loads(batch_cache.read_text())
        else:
            reply = get_json('https://datasets-server.huggingface.co/rows?' + params)
            batch_cache.parent.mkdir(exist_ok=True)
            save_json(batch_cache,reply)
        for record in reply['rows']:
            if record.get('truncated_cells'):
                raise RuntimeError(f'truncated dataset fields: {record["truncated_cells"]}')
            row = record['row']
            if isinstance(row.get('image'), dict):
                # Signed asset URLs contain the exact dataset revision. Never accept an unpinned image.
                if f'/--/{revision}/--/' not in row['image']['src']:
                    raise RuntimeError('viewer image revision differs from pinned dataset')
            out.append(row)
        offset += len(reply['rows'])
        if offset >= reply['num_rows_total']:
            return out
        if not reply['rows']:
            raise RuntimeError('dataset viewer stopped before end')


def prepare(name, cap=500):
    dataset, revision, layout, _, _ = SUBSETS[name]
    folder = ROOT / name
    folder.mkdir(exist_ok=True)
    cache = folder / 'metadata.json'
    if cache.exists():
        state = json.loads(cache.read_text())
        if state['cap'] != cap or state['revision'] != revision:
            raise RuntimeError('metadata checkpoint configuration changed')
        if state.get('schema') == 2:
            return state
    current = get_json(f'https://huggingface.co/api/datasets/{dataset}')
    if current['sha'] != revision:
        raise RuntimeError('viewer metadata is not at the pinned dataset revision')
    pages, queries, qrels = {}, {}, {}
    if layout == 'v1':
        for row in rows(dataset, revision):
            pid = row['image_filename']
            # Never use benchmark answers, generated prompts, or summaries as document text/title.
            parent = pid.rsplit('/', 1)[0]
            doc = parent if parent.endswith('.pdf') else (Path(pid).stem.rsplit('_',1)[0] if name == 'arxivqa' else pid)
            title = Path(parent).stem if parent.endswith('.pdf') else Path(urlparse(pid).path).stem
            pages[pid] = {'id': pid, 'doc': doc, 'title': title,
                          'image_url': row['image']['src']}
            if name == 'infovqa':
                serialized = ast.literal_eval(row['ocr'])
                lines = []
                for item in serialized:
                    parsed = json.loads(item)
                    lines.extend(b['Text'] for b in parsed.get('LINE', []) if b.get('Text'))
                pages[pid]['text'] = '\n'.join(lines)
            query = row.get('query')
            if query and query.strip():
                qid = hashlib.sha256(query.strip().encode()).hexdigest()[:20]
                queries[qid] = query.strip()
                qrels.setdefault(qid, {})[pid] = 1
    else:
        for row in rows(dataset, revision, 'corpus'):
            pid = str(row['corpus-id'])
            pages[pid] = {'id': pid, 'doc': row['doc-id'], 'title': Path(row['doc-id']).stem,
                          'image_url': row['image']['src']}
        for row in rows(dataset, revision, 'queries'):
            queries[str(row['query-id'])] = row['query']
        for row in rows(dataset, revision, 'qrels'):
            if row['score'] > 0:
                qrels.setdefault(str(row['query-id']), {})[str(row['corpus-id'])] = row['score']
    all_pages = len(pages)
    text_source = 'local tesseract 5.5.3, eng, psm 3; no source PDF text layer available'
    if name in ['energy','shift','ai']:
        _, text_dataset, text_revision = SUBSETS[name][3]
        descriptions = {}
        for row in rows(text_dataset, text_revision):
            descriptions.setdefault(row['image_filename'], row['text_description'])
        for pid, page in pages.items():
            if pid not in descriptions:
                raise RuntimeError('dataset OCR is missing a page')
            page['text'] = descriptions[pid]
        text_source = f'dataset text_description, {text_dataset}@{text_revision}; OCR, not a PDF text layer'
    elif name == 'infovqa':
        text_source = 'dataset ocr field, supplied LINE blocks in supplied order; not a PDF text layer'
    rng = random.Random(SEED)
    positive_pages = set().union(*(set(r) for r in qrels.values()))
    if layout == 'v2' and len(positive_pages) <= cap:
        chosen = positive_pages | set(rng.sample(sorted(set(pages)-positive_pages),
                                                min(cap-len(positive_pages),len(pages)-len(positive_pages))))
        sampling = 'all annotated positive pages plus seeded random distractors to page cap'
    else:
        chosen = set(rng.sample(sorted(pages), min(cap, len(pages))))
        sampling = 'seeded random page sample, independent of relevance labels'
    pages = {k: pages[k] for k in sorted(chosen)}
    # Keep only queries whose entire annotated positive set remains in the sampled corpus.
    # This avoids treating a removed positive as a negative or changing the recall denominator.
    qrels = {q: rel for q, rel in qrels.items() if rel and set(rel) <= chosen}
    queries = {q: queries[q] for q in qrels}
    state = dict(schema=2, name=name, dataset=dataset, revision=revision, cap=cap, source_pages=all_pages,
                 pages=list(pages.values()), queries=queries, qrels=qrels, sampling=sampling,
                 text_source=text_source)
    save_json(cache,state)
    return state


if __name__ == '__main__':
    import sys
    for name in sys.argv[1:] or ['energy']:
        state = prepare(name)
        print(name, len(state['pages']), len(state['queries']), flush=True)
