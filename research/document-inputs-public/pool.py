"""Rank against all 3000 pages together, using only completed embedding checkpoints."""
import hashlib
import json

import numpy as np

from durable import save_json
from evaluate import summarize
from guard import ROOT
from run import HERE,VARIANTS,evaluate_subset,fingerprint

OWNER_SETS={'energy','shift','ai','biomedical_lectures'}


def main():
    results=json.loads((HERE/'results.json').read_text())
    if results['status']!='complete':raise RuntimeError('all subset runs must complete before merged ranking')
    pages=[]
    inputs=[]
    vectors={v:[] for v in VARIANTS}
    queries={}
    qrels={}
    query_vectors={}
    sources={}
    source_pages=0
    for name,summary in results['subsets'].items():
        state=json.loads((ROOT/name/'metadata.json').read_text())
        if summary['fingerprint']!=fingerprint(state):raise RuntimeError('pooled checkpoint inputs changed')
        stats=json.loads((HERE/f'inputs-{name}.json').read_text())
        source_pages+=state['source_pages']
        page_ids={p['id']:name+':'+p['id'] for p in state['pages']}
        for page,info in zip(state['pages'],stats):
            pid=page_ids[page['id']]
            doc=name+':'+page['doc']
            pages.append(dict(id=pid,doc=doc))
            inputs.append(dict(info,page_id=pid,doc=doc))
        with np.load(ROOT/name/'embeddings.npz',allow_pickle=False) as cache:
            for v in VARIANTS:vectors[v].append(cache[v])
            qvectors=cache['queries']
        for i,(old_qid,text) in enumerate(state['queries'].items()):
            qid=hashlib.sha256(text.encode()).hexdigest()
            queries[qid]=text
            query_vectors.setdefault(qid,qvectors[i])
            sources.setdefault(qid,set()).add(name)
            for pid,grade in state['qrels'][old_qid].items():
                qrels.setdefault(qid,{})[page_ids[pid]]=grade
    order=sorted(range(len(pages)),key=lambda i:pages[i]['id'])
    pages=[pages[i] for i in order]
    inputs=[inputs[i] for i in order]
    vectors={v:np.concatenate(a)[order] for v,a in vectors.items()}
    state=dict(name='merged',dataset=list(results['subsets']),revision='pinned revisions in individual subset summaries',
               pages=pages,queries=queries,qrels=qrels,source_pages=source_pages,
               text_source='same OCR and vectors as the individual subset runs',
               sampling='union of fixed subset corpora; exact duplicate queries share the union of their positives')
    qvectors=np.stack([query_vectors[q] for q in queries])
    report,arrays,clusters=evaluate_subset(state,vectors,qvectors,inputs)
    mask=np.array([bool(sources[q]&OWNER_SETS) for q in queries])
    owner=summarize({v:a[mask] for v,a in arrays.items()},np.array(clusters)[mask])
    owner['corpus_pages']=len(pages)
    results['merged_corpus']=report
    results['merged_owner_queries']=owner
    save_json(HERE/'metrics-merged.json',{'clusters':clusters,'owner_query_mask':mask.tolist(),
                                         'values':{v:a.tolist() for v,a in arrays.items()}})
    save_json(HERE/'results.json',results)
    print('MERGED COMPLETE',len(pages),'pages',len(queries),'unique queries',int(mask.sum()),'report/lecture queries',flush=True)


if __name__=='__main__':main()
