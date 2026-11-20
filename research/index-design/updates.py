#!/usr/bin/env python3
"""Committed one-segment ingest/delete cycles on expendable copies."""
import json
from pathlib import Path
import statistics
import time
from study import connect,clone,pack,reference_pack


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    source=connect(scratch/'baseline.sqlite')
    row=source.execute('''SELECT s.kind,s.modality,s.loc,s.loc_end,s.excerpt,s.vec,
        f.c0,f.c1,f.c2,i.input,i.content_rev,v.vec
        FROM segments s JOIN fts_content f ON f.id=s.id JOIN embedding_inputs i ON i.segment=s.id
        JOIN vectors v ON v.segment=s.id AND v.model=2 WHERE s.modality='text' LIMIT 1''').fetchone()
    out={}
    for mode,filename in (('baseline','baseline.sqlite'),('compact','backend-compacted.sqlite'),('reference','fts-reference-external.sqlite')):
        c=clone(scratch/filename,scratch/f'updates-{mode}.sqlite')
        c.execute('PRAGMA foreign_keys=ON')
        c.execute('PRAGMA journal_mode=WAL')
        c.execute('PRAGMA synchronous=NORMAL')
        c.execute('PRAGMA wal_autocheckpoint=0')
        insert_times=[];delete_times=[]
        for i in range(50):
            start=time.perf_counter()
            c.execute('BEGIN IMMEDIATE')
            file=c.execute('''INSERT INTO files(path,kind,size,mtime,inode,device,state,indexed_at)
                VALUES(?,'doc',100,0,0,0,'done',0)''',(f'/synthetic-index-research/{i}',)).lastrowid
            table='packed_segments' if mode=='reference' else 'segments'
            excerpt=reference_pack(row[4],row[6:9]) if mode=='reference' else row[4]
            segment=c.execute(f'INSERT INTO {table}(file,kind,modality,loc,loc_end,excerpt,vec) VALUES(?,?,?,?,?,?,?)',
                              (file,*row[:4],excerpt,row[5])).lastrowid
            if mode=='reference':
                c.execute('INSERT INTO keyword_payload VALUES(?,?,?,?)',(segment,*(pack(v) for v in row[6:9])))
            c.execute('INSERT INTO fts(rowid,name,body,original) VALUES(?,?,?,?)',(segment,*row[6:9]))
            input_table='packed_embedding_inputs' if mode=='reference' else 'embedding_inputs'
            input_value=reference_pack(row[9],row[6:9]) if mode=='reference' else row[9]
            c.execute(f'INSERT INTO {input_table} VALUES(?,?,?)',(segment,input_value,row[10]))
            c.execute('INSERT INTO vectors VALUES(2,?,?,?,?)',(segment,row[10],row[1],row[11]))
            c.commit()
            insert_times.append((time.perf_counter()-start)*1000)
            assert c.execute('SELECT input FROM embedding_inputs WHERE segment=?',(segment,)).fetchone()[0]==row[9]
            assert c.execute('SELECT excerpt FROM segments WHERE id=?',(segment,)).fetchone()[0]==row[4]
            start=time.perf_counter()
            c.execute('BEGIN IMMEDIATE')
            if mode=='reference':
                c.execute("INSERT INTO fts(fts,rowid,name,body,original) VALUES('delete',?,?,?,?)",(segment,*row[6:9]))
                c.execute('DELETE FROM keyword_payload WHERE id=?',(segment,))
            else:
                c.execute('DELETE FROM fts WHERE rowid=?',(segment,))
            c.execute('DELETE FROM files WHERE id=?',(file,))
            c.commit()
            delete_times.append((time.perf_counter()-start)*1000)
        assert not c.execute('PRAGMA foreign_key_check').fetchall()
        c.execute("INSERT INTO fts(fts,rank) VALUES('integrity-check',1)")
        c.commit()
        c.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall()
        def stats(values):return {'median_ms':statistics.median(values),'p95_ms':sorted(values)[47]}
        out[mode]={'iterations':50,'insert':stats(insert_times),'delete':stats(delete_times),'integrity':'ok','fk_violations':0}
        c.close()
        (scratch/'updates.json').write_text(json.dumps(out,indent=2))
        print(mode,'update cycles complete',flush=True)


if __name__=='__main__':main()
