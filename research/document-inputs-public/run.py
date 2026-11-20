"""Resumable MPS/CPU benchmark. Page images are removed after embedding, except public parity fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time
from urllib.parse import parse_qs, urlparse, urlencode

import numpy as np
from PIL import Image

from data import prepare
from eg2ref import Reference, image_ids, mixed_ids, prepare_image, snapshot_dir
from evaluate import MODALITIES, metric, score, selections, summarize
from guard import ROOT, check, get_json, fetch
from subsets import SUBSETS
from durable import save_json,write_atomic
from eg2ref import REVISION

HERE = Path(__file__).resolve().parent
VARIANTS = ['T', 'I', 'V2', 'V2_text_image', 'prompt_image']
PROTOCOL='original-fp32-padded-v3-persistent'


def fingerprint(state):
    data={k:v for k,v in state.items() if k!='pages'}
    data['pages']=[{k:v for k,v in p.items() if k!='image_url'} for p in state['pages']]
    data.update(protocol=PROTOCOL,model_revision=REVISION,
                reference_sha256=hashlib.sha256((HERE/'eg2ref.py').read_bytes()).hexdigest())
    return hashlib.sha256(json.dumps(data,sort_keys=True).encode()).hexdigest()


def commit_subset(name):
    paths=[HERE/f'summary-{name}.json',HERE/f'metrics-{name}.json',HERE/f'inputs-{name}.json',
           HERE/'results.json',HERE/'STATUS.md']
    root=HERE.parent.parent
    branch=subprocess.check_output(['git','branch','--show-current'],cwd=root,text=True).strip()
    expected_branch=os.environ.get('SWIFTLIGHT_BENCH_BRANCH')
    if expected_branch and branch!=expected_branch:
        raise RuntimeError('refusing subset commit on an unexpected branch')
    relative=[str(p.relative_to(root)) for p in paths]
    subprocess.run(['git','add','--',*relative],cwd=root,check=True)
    changed=subprocess.run(['git','diff','--cached','--quiet','--',*relative],cwd=root)
    if changed.returncode==1:
        subprocess.run(['git','commit','--only','-m',f'Record completed public benchmark subset: {name}','--',*relative],
                       cwd=root,check=True)
    elif changed.returncode!=0:
        raise RuntimeError('cannot inspect staged subset results')


def page_inputs(page, folder):
    path = folder / (hashlib.sha256(page['id'].encode()).hexdigest()[:20] + '.jpg')
    textpath = path.with_suffix('.txt')
    if not path.exists():
        expiry = int(parse_qs(urlparse(page['image_url']).query).get('Expires', ['0'])[0])
        if expiry < time.time() + 120:
            dataset, revision, layout, _, _ = SUBSETS[folder.name]
            rowindex = int(page['image_url'].split('/test/')[1].split('/')[0])
            params = urlencode(dict(dataset=dataset, config='default' if layout=='v1' else 'corpus',
                                    split='test', offset=rowindex, length=1))
            renewed = get_json('https://datasets-server.huggingface.co/rows?' + params)['rows'][0]['row']
            url = renewed['image']['src']
            if f'/--/{revision}/--/' not in url:
                raise RuntimeError('renewed asset is not the pinned revision')
            page['image_url'] = url
        fetch(page['image_url'], path)
    with Image.open(path) as original:
        rgb = original.convert('RGB')
        # Public raster pages substitute for PDFKit's 1400-pixel PDF rendering.
        # Match fit-without-upscaling; save these exact pixels in parity fixtures.
        rgb.thumbnail((1400, 1400), Image.Resampling.BICUBIC)
        image = np.asarray(rgb).copy()
    if 'text' in page:
        textpath.write_text(page['text'])
    elif not textpath.exists():
        ocr = subprocess.run(['tesseract', str(path), 'stdout', '-l', 'eng', '--psm', '3'],
                             capture_output=True, text=True, check=True)
        textpath.write_text(ocr.stdout)
    text = textpath.read_text()
    return image, text, path


def normalized(hidden):
    v = hidden[0].float().mean(0)
    return (v / v.norm()).cpu().numpy()


def parity(ref, state):
    """Validate manual hard/soft-token insertion against the public model's full forward."""
    import torch
    import transformers
    from transformers import AutoImageProcessor
    outdir = ROOT / 'parity-fixtures'
    outdir.mkdir(exist_ok=True)
    records, checks = [], []
    texts = [('query', q) for q in list(state['queries'].values())[:5]]
    texts += [('document', ('Public reference', s)) for s in [
        'Solar and wind generation vary with weather. Storage can shift energy to periods of higher demand.',
        'Dijkstra\'s algorithm finds shortest paths when edge weights are nonnegative.',
        'Annual report: operating expenses increased while electricity consumption declined.']]
    for index, (kind, value) in enumerate(texts):
        ids = ref.tokens.query(value) if kind == 'query' else ref.tokens.document(*value)
        ours = ref.run(ids)
        with torch.inference_mode():
            native = normalized(ref.model(input_ids=torch.tensor([ids], device=ref.device)).last_hidden_state)
        cosine = float(ours @ native)
        checks.append({'kind': kind, 'cosine_manual_vs_native': cosine})
        if cosine < 0.99:
            raise RuntimeError('text reference paths fail parity')
        records.append(dict(name=f'{kind}-{index}', kind=kind, input=value, token_ids=ids, vector=ours.tolist()))
    processor = AutoImageProcessor.from_pretrained(snapshot_dir(), local_files_only=True)
    for index, page in enumerate(state['pages'][:2]):
        rgb, text, path = page_inputs(page, ROOT / state['name'])
        pv, positions, n, resized = prepare_image(rgb)
        image_file = outdir / f'public-page-{index}.png'
        Image.fromarray(rgb).save(image_file)
        native_prep = processor(images=Image.fromarray(rgb), return_tensors='np', max_soft_tokens=280)
        # Check the independently maintained HF processor, including patch coordinates and patch pixels.
        native_pixels = np.asarray(native_prep['pixel_values'])
        native_positions = np.asarray(native_prep['image_position_ids'])
        positions_equal = np.array_equal(positions, native_positions)
        pixel_error = float(np.max(np.abs(pv - native_pixels)))
        if not positions_equal or pixel_error > 1.01 / 255:
            raise RuntimeError(f'image preprocessing differs: positions={positions_equal}, pixels={pixel_error}')
        soft = ref.soft_tokens(pv, positions)
        ids = image_ids(n)
        ours = ref.run(ids, soft)
        with torch.inference_mode():
            native = normalized(ref.model(input_ids=torch.tensor([ids], device=ref.device),
                                           pixel_values=torch.from_numpy(pv).to(ref.device),
                                           image_position_ids=torch.from_numpy(positions).to(ref.device)).last_hidden_state)
        cosine = float(ours @ native)
        if cosine < 0.99:
            raise RuntimeError('image insertion paths fail parity')
        checks.append(dict(kind='image', cosine_manual_vs_native=cosine, positions_equal=positions_equal,
                           max_pixel_error=pixel_error, soft_tokens=n, resized_shape=list(resized.shape)))
        base = dict(image=image_file.name, image_sha256=hashlib.sha256(image_file.read_bytes()).hexdigest(),
                    dataset=state['dataset'], revision=state['revision'], page_id=page['id'], budget=280,
                    resized_height=resized.shape[0], resized_width=resized.shape[1], soft_tokens=n)
        records.append(dict(name=f'image-{index}', kind='image', token_ids=ids, vector=ours.tolist(), **base))
        if index == 0:
            mixed, trimmed = mixed_ids(ref.tokens, page['title'], text, n, 'image_text')
            vector = ref.run(mixed, soft)
            with torch.inference_mode():
                native = normalized(ref.model(input_ids=torch.tensor([mixed], device=ref.device),
                                               pixel_values=torch.from_numpy(pv).to(ref.device),
                                               image_position_ids=torch.from_numpy(positions).to(ref.device)).last_hidden_state)
            cosine = float(vector @ native)
            if cosine < 0.99:
                raise RuntimeError('mixed insertion paths fail parity')
            checks.append(dict(kind='mixed', cosine_manual_vs_native=cosine))
            records.append(dict(name='mixed-0', kind='mixed', title=page['title'], text=text,
                                token_ids=mixed, trimmed_tokens=trimmed, order='image_text', vector=vector.tolist(), **base))
        path.unlink()
    result = dict(device=ref.device, dtype='float32', torch=torch.__version__, transformers=transformers.__version__,
                  platform=platform.platform(), checks=checks,
                  production_CoreAI_parity='pending external replay; these checks compare PyTorch paths only')
    save_json(outdir / 'fixtures.json', {'reference': result, 'fixtures': records})
    save_json(HERE / 'parity.json', result)
    print('PARITY', json.dumps(checks), flush=True)
    return result


def embed_subset(ref, name, cap):
    state = prepare(name, cap)
    folder = ROOT / name
    checkpoint = folder / 'embeddings.npz'
    metadata = folder / 'page-inputs.json'
    identity=fingerprint(state)
    protocol_file=folder/'checkpoint-protocol.json'
    if protocol_file.exists() and json.loads(protocol_file.read_text())['fingerprint']!=identity:
        raise RuntimeError(f'{name}: checkpoint inputs or reference changed')
    save_json(protocol_file,{'fingerprint':identity,'protocol':PROTOCOL})
    complete=folder/'embeddings-complete.json'
    if complete.exists():
        if json.loads(complete.read_text())['fingerprint']!=identity:
            raise RuntimeError('completed checkpoint does not match inputs')
        with np.load(checkpoint,allow_pickle=False) as old:
            vectors={v:old[v] for v in VARIANTS}
            query_vectors=old['queries']
        print(name,'SKIP completed embedding checkpoint',flush=True)
        return state,vectors,query_vectors,json.loads(metadata.read_text())
    n = len(state['pages'])
    vectors = {v: np.full((n, 768), np.nan, dtype=np.float32) for v in VARIANTS}
    query_vectors = np.full((len(state['queries']), 768), np.nan, dtype=np.float32)
    inputs = [None]*n
    pages_folder=folder/'page-checkpoints'
    queries_folder=folder/'query-checkpoints'
    pages_folder.mkdir(exist_ok=True)
    queries_folder.mkdir(exist_ok=True)
    for i,page in enumerate(state['pages']):
        item=pages_folder/f'{i:05d}.npz'
        if item.exists():
            with np.load(item,allow_pickle=False) as saved:
                assert str(saved['fingerprint'])==identity
                info=json.loads(str(saved['info']))
                assert info['page_id']==page['id']
                for v in VARIANTS:
                    vector=saved[v]
                    assert vector.shape==(768,) and np.isfinite(vector).all()
                    vectors[v][i]=vector
                inputs[i]=info

    def checkpoint_now():
        check(20_000_000)
        save_json(metadata, inputs)
        write_atomic(checkpoint,lambda stream:np.savez_compressed(stream,**vectors,queries=query_vectors))

    for i, (qid,q) in enumerate(state['queries'].items()):
        path=queries_folder/(hashlib.sha256(qid.encode()).hexdigest()+'.npy')
        if path.exists():
            query_vectors[i]=np.load(path,allow_pickle=False)
        else:
            if ref is None:raise RuntimeError('missing query checkpoint')
            vector=ref.run(ref.tokens.query(q))
            write_atomic(path,lambda stream:np.save(stream,vector,allow_pickle=False))
            query_vectors[i]=vector
    for i, page in enumerate(state['pages']):
        if all(np.isfinite(vectors[v][i]).all() for v in VARIANTS) and inputs[i] is not None:
            continue
        if ref is None:raise RuntimeError('missing page checkpoint')
        check(20_000_000)
        start = time.perf_counter()
        rgb, text, path = page_inputs(page, folder)
        prepared = time.perf_counter()
        pv, positions, nsoft, resized = prepare_image(rgb)
        resampled = time.perf_counter()
        soft = ref.soft_tokens(pv, positions)
        vision_done = time.perf_counter()
        ids = {'T': ref.tokens.document(page['title'], text), 'I': image_ids(nsoft)}
        trims = {}
        for variant, order in [('V2', 'image_text'), ('V2_text_image', 'text_image'), ('prompt_image', 'image_only')]:
            ids[variant], trims[variant] = mixed_ids(ref.tokens, page['title'], text, nsoft, order)
        for variant in VARIANTS:
            vectors[variant][i] = ref.run(ids[variant], None if variant == 'T' else soft)
        import regex
        info = dict(page_id=page['id'], doc=page['doc'], text_characters=len(regex.findall(r'\X', text)),
                    text_sha256=hashlib.sha256(text.encode()).hexdigest(), soft_tokens=nsoft,
                    token_counts={v: len(x) for v, x in ids.items()}, trimmed_tokens=trims,
                    seconds=time.perf_counter() - start,
                    stage_seconds={'download_and_ocr': prepared-start,'resize_and_patches':resampled-prepared,
                                   'vision':vision_done-resampled,'five_text_prefills':time.perf_counter()-vision_done})
        inputs[i] = info
        item=pages_folder/f'{i:05d}.npz'
        write_atomic(item,lambda stream:np.savez_compressed(stream,**{v:vectors[v][i] for v in VARIANTS},
                                                          info=np.array(json.dumps(info)),fingerprint=np.array(identity)))
        path.unlink()
        if (i + 1) % 10 == 0 or i + 1 == n:
            checkpoint_now()
            gpu_mb = ref.torch.mps.driver_allocated_memory()/1e6 if ref.device=='mps' else 0
            print(name, f'{i+1}/{n}', 'last_seconds', round(info['seconds'], 2), 'free_GB', round(check()/1e9, 2),
                  'MPS_driver_MB', round(gpu_mb,1), flush=True)
    checkpoint_now()
    save_json(complete,{'fingerprint':identity,'pages':n,'queries':len(query_vectors),'completed_at':time.time()})
    return state, vectors, query_vectors, inputs


def evaluate_subset(state, vectors, query_vectors, inputs):
    pages = state['pages']
    pindex = {p['id']: i for i, p in enumerate(pages)}
    selected = selections([p['text_characters'] for p in inputs])
    values = {v: [] for v in selected}
    clusters = []
    for qi, qid in enumerate(state['queries']):
        rel = state['qrels'][qid]
        relevance = np.zeros(len(pages))
        for p, grade in rel.items():
            relevance[pindex[p]] = grade
        clusters.append(state['name'] + ':' + pages[pindex[sorted(rel)[0]]]['doc'])
        for variant, rows in selected.items():
            scores = score(query_vectors[qi], vectors, rows, MODALITIES, len(pages), raw=variant=='V1_raw')
            values[variant].append(metric(scores, relevance))
    arrays = {v: np.array(x) for v, x in values.items()}
    report = summarize(arrays, clusters)
    report.update(dataset=state['dataset'], revision=state['revision'], pages=len(pages),
                  source_pages=state['source_pages'], text_source=state['text_source'],
                  sampling=state.get('sampling','seeded random page sample, independent of relevance labels'),
                  production_text_pages=sum(p['text_characters'] >= 200 for p in inputs))
    return report, arrays, clusters


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--subsets', nargs='+', default=['energy','shift','arxivqa','infovqa','ai','biomedical_lectures'])
    parser.add_argument('--cap', type=int, default=500)
    parser.add_argument('--device', choices=['mps','cpu'], default='mps')
    parser.add_argument('--parity-only', action='store_true')
    parser.add_argument('--recheck-parity', action='store_true')
    parser.add_argument('--no-commit',action='store_true',help='For isolated runner verification only')
    args = parser.parse_args()
    check()
    first = prepare(args.subsets[0], args.cap)
    parity_marker=ROOT/'parity-validated.json'
    parity_identity={'protocol':PROTOCOL,'reference_sha256':hashlib.sha256((HERE/'eg2ref.py').read_bytes()).hexdigest(),
                     'device':args.device}
    needs_inference=any(not (ROOT/name/'embeddings-complete.json').exists() for name in args.subsets)
    need_parity=args.parity_only or args.recheck_parity or not parity_marker.exists() or json.loads(parity_marker.read_text())!=parity_identity
    ref=Reference(args.device,threads=4) if needs_inference or need_parity else None
    if need_parity:
        parity(ref,first)
        save_json(parity_marker,parity_identity)
    else:
        print('SKIP previously verified parity',flush=True)
    if args.parity_only:
        return
    reports={name:json.loads((HERE/f'summary-{name}.json').read_text()) for name in args.subsets
             if (HERE/f'summary-{name}.json').exists()}
    pooled, clusters, loaded = {}, [], {}
    for name in args.subsets:
        state, vectors, queries, inputs = embed_subset(ref, name, args.cap)
        summary_path=HERE/f'summary-{name}.json'
        metrics_path=HERE/f'metrics-{name}.json'
        new_result=not (summary_path.exists() and metrics_path.exists())
        if not new_result:
            report=json.loads(summary_path.read_text())
            if report.get('fingerprint')!=fingerprint(state):raise RuntimeError('completed results fingerprint changed')
            cached=json.loads(metrics_path.read_text())
            arrays={v:np.array(a) for v,a in cached['values'].items()}
            groups=cached['clusters']
            print(name,'SKIP completed evaluation',flush=True)
        else:
            report, arrays, groups = evaluate_subset(state, vectors, queries, inputs)
            report['fingerprint']=fingerprint(state)
            save_json(metrics_path, {'clusters':groups, 'values':{v:a.tolist() for v,a in arrays.items()}})
            save_json(HERE / f'inputs-{name}.json', inputs)
            save_json(summary_path,report)
        reports[name] = report
        loaded[name] = (state, vectors, queries, inputs)
        for v, a in arrays.items():
            pooled.setdefault(v, []).append(a)
        clusters += groups
        aggregate=HERE/'results.json'
        prior=json.loads(aggregate.read_text()) if aggregate.exists() else {}
        if new_result or set(prior.get('subsets',{}))!=set(reports):
            save_json(aggregate, {'status':'running', 'subsets': reports})
        status=['# Public benchmark progress','',f'Protocol: `{PROTOCOL}`. Persistent cache: `~/.swiftlight-research/public-bench/`.','',
                '| Completed subset | Pages | Queries | P nDCG@5 | V1 nDCG@5 | V2 nDCG@5 |','|---|---:|---:|---:|---:|---:|']
        for label,s in reports.items():
            status.append(f"| {label} | {s['pages']} | {s['queries']} | {s['variants']['P']['nDCG@5']['value']:.4f} | {s['variants']['V1']['nDCG@5']['value']:.4f} | {s['variants']['V2']['nDCG@5']['value']:.4f} |")
        write_atomic(HERE/'STATUS.md',lambda stream:stream.write(('\n'.join(status)+'\n').encode()))
        if not args.no_commit:commit_subset(name)
    results = dict(status='complete', subsets=reports,
                   pooled=summarize({v:np.concatenate(a) for v,a in pooled.items()}, clusters))
    results['no_answer'] = []
    for source, target in [('arxivqa','infovqa'), ('infovqa','arxivqa')]:
        if source not in loaded or target not in loaded:
            continue
        _, _, queries, _ = loaded[source]
        state, vectors, _, inputs = loaded[target]
        selected = selections([p['text_characters'] for p in inputs])
        counts = {v: {str(g): 0 for g in [2.5,3.0,4.5]} for v in selected if v != 'V1_raw'}
        for q in queries:
            for v in counts:
                top = score(q, vectors, selected[v], MODALITIES, len(inputs)).max()
                for gate in counts[v]:
                    counts[v][gate] += int(top >= float(gate))
        results['no_answer'].append(dict(query_subset=source, corpus_subset=target, queries=len(queries),
                                         corpus_pages=len(state['pages']), counts=counts,
                                         caveat='cross-subset queries are presumed unanswerable; not manually relabeled'))
    save_json(HERE / 'results.json', results)
    ledgers={p.name:json.loads(p.read_text()) for p in [ROOT/'downloads.json',ROOT/'prefetch-downloads.json'] if p.exists()}
    save_json(HERE/'downloads.json', {'bytes':sum(v['bytes'] for v in ledgers.values()),
                                     'reserve_bytes':sum(v['reserve_bytes'] for v in ledgers.values()),
                                     'requests':sum(v['requests'] for v in ledgers.values()),'ledgers':ledgers})
    print('COMPLETE', flush=True)


if __name__ == '__main__':
    main()
