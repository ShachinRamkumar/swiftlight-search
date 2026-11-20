#!/usr/bin/env python3
"""Remove duplicated text through verified byte references, with compressed fallback."""
import json
from pathlib import Path
import time
from study import (ROOT,connect,clone,rebuild_fts,compress_columns,compact,size,
                   queries,keyword_bench,logical_digest,update_bench)


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    source=connect(scratch/'baseline.sqlite')
    target=scratch/'fts-reference-external.sqlite'
    c=clone(scratch/'baseline.sqlite',target)
    start=time.perf_counter()
    rebuild_fts(c,source,compressed=True)
    compress_columns(c,references=True)
    compact(c,16384)
    out={'bytes':size(c),'migration_ms':(time.perf_counter()-start)*1000}
    out['references']={}
    for table,col in (('packed_embedding_inputs','input'),('packed_segments','excerpt')):
        out['references'][table]=[list(r) for r in c.execute(f"SELECT cast(substr({col},1,1) AS TEXT),count(*),sum(length({col})) FROM {table} WHERE {col} IS NOT NULL GROUP BY substr({col},1,1)")]
    out['logical_parity']={t:logical_digest(c,t,o)==logical_digest(source,t,o) for t,o in
                           (('segments','id'),('embedding_inputs','segment'),('vectors','model,segment'),('files','id'),('fts','rowid'))}
    out['integrity']=c.execute('PRAGMA integrity_check').fetchone()[0]
    out['foreign_key_violations']=len(c.execute('PRAGMA foreign_key_check').fetchall())
    c.execute("INSERT INTO fts(fts,rank) VALUES('integrity-check',1)")
    out['objects']=[dict(zip(('name','bytes'),r)) for r in c.execute('SELECT name,sum(pgsize) FROM dbstat GROUP BY name')]
    qs=queries(source,scratch/'queries.json')
    expected=keyword_bench(source,qs)[1]
    out['keyword']=keyword_bench(c,qs,expected)[0]
    out['update']=update_bench(c,True)
    (scratch/'references.json').write_text(json.dumps(out,indent=2))
    print('reference migration and parity complete',flush=True)


if __name__=='__main__':main()
