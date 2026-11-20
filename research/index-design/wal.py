#!/usr/bin/env python3
"""Checkpoint-policy sweep with and without a pinned reader, on expendable copies."""
import json
from pathlib import Path
import statistics
import time
from study import clone,connect,timer


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    out={}
    for threshold in (64,256,1000):
        for pinned in (False,True):
            path=scratch/'wal-policy.sqlite'
            c=clone(scratch/'backend-compacted.sqlite',path)
            c.execute('PRAGMA journal_mode=WAL')
            c.execute('PRAGMA synchronous=NORMAL')
            c.execute(f'PRAGMA wal_autocheckpoint={threshold}')
            c.execute('PRAGMA journal_size_limit=8388608')
            reader=connect(path)
            if pinned:
                reader.execute('BEGIN');reader.execute('SELECT count(*) FROM files').fetchone()
            ident=c.execute("SELECT id FROM segments WHERE kind='name' LIMIT 1").fetchone()[0]
            old=c.execute('SELECT name FROM fts WHERE rowid=?',(ident,)).fetchone()[0]
            times=[];peak=0
            for i in range(200):
                start=time.perf_counter()
                c.execute('UPDATE fts SET name=? WHERE rowid=?',('synthetic checkpoint name' if i%2==0 else old,ident))
                c.commit();times.append((time.perf_counter()-start)*1000)
                peak=max(peak,Path(str(path)+'-wal').stat().st_size)
            passive=c.execute('PRAGMA wal_checkpoint(PASSIVE)').fetchone()
            reader.rollback();reader.close()
            checkpoint=timer(lambda:c.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchall())
            out[f'{threshold}-'+('pinned' if pinned else 'short-readers')]={
                'transactions':200,'median_ms':statistics.median(times),'p95_ms':sorted(times)[190],
                'peak_wal_bytes':peak,'passive_before_reader_release':list(passive),'truncate_after_reader_release':checkpoint}
            c.close();path.unlink()
            (scratch/'wal.json').write_text(json.dumps(out,indent=2));print(threshold,pinned,'complete',flush=True)


if __name__=='__main__':main()
