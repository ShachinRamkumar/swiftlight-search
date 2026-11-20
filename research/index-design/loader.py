#!/usr/bin/env python3
"""Measure removing the vector loader's forced materialization; keep explicit ordering."""
import json
from pathlib import Path
from study import connect,timer


def sql(selected,materialized,files=None):
    cols="s.file,s.modality,s.kind,s.loc"
    pages="CAST(json_extract(f.info,'$.pages') AS INTEGER)"
    filter=' AND s.file IN ('+','.join(map(str,files))+')' if files else ''
    cte="WITH model_vectors AS MATERIALIZED (SELECT segment,vec FROM vectors WHERE model=2) " if materialized and files is None else ''
    table='model_vectors' if cte else 'vectors'
    model='' if cte else 'v.model=2 AND '
    return (f'{cte}SELECT {cols},v.vec,{pages},v.segment AS sort_id FROM {table} v JOIN segments s ON s.id=v.segment JOIN files f ON f.id=s.file '
            f'WHERE {model}s.modality IN {selected} AND v.vec IS NOT NULL{filter} '
            f'UNION ALL SELECT {cols},s.vec,{pages},s.id AS sort_id FROM segments s JOIN files f ON f.id=s.file '
            f'WHERE s.modality NOT IN {selected} AND s.vec IS NOT NULL{filter} ORDER BY sort_id')


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    out={}
    for name,path in [('baseline','baseline.sqlite'),('reference','fts-reference-external.sqlite')]:
        c=connect(scratch/path);out[name]={}
        for policy,selected in [('all',"('text','image')"),('text',"('text')")]:
            a=sql(selected,True);b=sql(selected,False)
            old=c.execute(a).fetchall();new=c.execute(b).fetchall()
            assert old==new
            row_count=len(old);del old,new
            def scan(q):return sum(len(r[4]) for r in c.execute(q))
            out[name][policy]={'rows':row_count,'all_selected_fields_and_order_equal':True,
                'materialized':timer(lambda:scan(a),12),'direct':timer(lambda:scan(b),12),
                'materialized_plan':[r[3] for r in c.execute('EXPLAIN QUERY PLAN '+a)],
                'direct_plan':[r[3] for r in c.execute('EXPLAIN QUERY PLAN '+b)]}
            fresh=[r[0] for r in c.execute('SELECT id FROM files ORDER BY id LIMIT 20')]
            assert c.execute(sql(selected,True,fresh)).fetchall()==c.execute(sql(selected,False,fresh)).fetchall()
        c.close()
    (scratch/'loader.json').write_text(json.dumps(out,indent=2));print('loader parity and timings complete',flush=True)


if __name__=='__main__':main()
