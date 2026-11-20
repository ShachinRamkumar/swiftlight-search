#!/usr/bin/env python3
"""Replay current scoring over both migrated snapshots; exercise update/delete adapters."""
import ctypes
import json
from pathlib import Path
import resource
import time
import numpy as np
from study import connect, pack, logical_digest
from vectors import collect, ptr, meaning


def lifecycle(c):
    c.execute('PRAGMA foreign_keys=ON')
    old=logical_digest(c,'vectors','model,segment')
    file=c.execute("SELECT file FROM segments WHERE modality='text' LIMIT 1").fetchone()[0]
    ids=[r[0] for r in c.execute('SELECT id FROM segments WHERE file=?',(file,))]
    marks=','.join('?' for _ in ids)
    start=time.perf_counter()
    c.execute('BEGIN IMMEDIATE')
    rows=c.execute(f'SELECT rowid,name,body,original FROM fts WHERE rowid IN ({marks})',ids).fetchall()
    for row in rows:
        c.execute("INSERT INTO fts(fts,rowid,name,body,original) VALUES('delete',?,?,?,?)",row)
    c.execute(f'DELETE FROM keyword_payload WHERE id IN ({marks})',ids)
    c.execute('DELETE FROM files WHERE id=?',(file,))
    assert c.execute('SELECT count(*) FROM segments WHERE file=?',(file,)).fetchone()[0]==0
    assert c.execute(f'SELECT count(*) FROM vectors WHERE segment IN ({marks})',ids).fetchone()[0]==0
    assert not c.execute('PRAGMA foreign_key_check').fetchall()
    c.execute("INSERT INTO fts(fts,rank) VALUES('integrity-check',1)")
    delete_ms=(time.perf_counter()-start)*1000
    c.rollback()
    assert logical_digest(c,'vectors','model,segment')==old
    segment=c.execute("SELECT id FROM segments WHERE modality='text' LIMIT 1").fetchone()[0]
    c.execute('BEGIN IMMEDIATE')
    oldtext=c.execute('SELECT name,body,original FROM fts WHERE rowid=?',(segment,)).fetchone()
    c.execute("INSERT INTO fts(fts,rowid,name,body,original) VALUES('delete',?,?,?,?)",(segment,*oldtext))
    # Required replacement for the old fts_content update hook, inside this transaction.
    c.execute('DELETE FROM packed_embedding_inputs WHERE segment=?',(segment,))
    c.execute('DELETE FROM embedding_failures WHERE segment=?',(segment,))
    c.execute('UPDATE packed_segments SET excerpt=? WHERE id=?',(pack('synthetic replacement'),segment))
    c.execute('UPDATE keyword_payload SET body=?,original=NULL WHERE id=?',(pack('synthetic replacement'),segment))
    c.execute('INSERT INTO fts(rowid,name,body,original) VALUES(?,?,?,NULL)',(segment,oldtext[0],'synthetic replacement'))
    assert c.execute('SELECT count(*) FROM vectors WHERE segment=?',(segment,)).fetchone()[0]==0
    assert not c.execute('PRAGMA foreign_key_check').fetchall()
    c.execute("INSERT INTO fts(fts,rank) VALUES('integrity-check',1)")
    c.rollback()
    assert logical_digest(c,'vectors','model,segment')==old
    return {'deleted_segments_in_rolled_back_file':len(ids),'delete_with_integrity_check_ms':delete_ms,
            'source_change_invalidates_vectors_atomically':True,'rollback_restores_vectors':True}


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    lib=ctypes.CDLL(str(scratch/'scan.dylib'))
    lib.make_codes.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    lib.int8_scan.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    baseline=connect(scratch/'baseline.sqlite')
    out={}
    for variant in ('backend','compressed','reference'):
        c=connect(scratch/('backend-compacted.sqlite' if variant=='backend' else f'fts-{variant}-external.sqlite'))
        result={'lifecycle':lifecycle(c) if variant!='backend' else 'original write schema retained','policies':{}}
        for policy in ('coreai-all','coreai-text-legacy-image'):
            old=collect(baseline,policy);new=collect(c,policy)
            assert old==new
            n=len(old)
            v=np.frombuffer(b''.join(r[-1] for r in old),dtype='<f2').reshape(n,768)
            w=np.frombuffer(b''.join(r[-1] for r in new),dtype='<f2').reshape(n,768)
            codes=np.empty((n,768),np.int8);codes2=np.empty_like(codes)
            scales=np.empty(n,np.float32);scales2=np.empty_like(scales)
            lib.make_codes(ptr(v),n,ptr(codes),ptr(scales));lib.make_codes(ptr(w),n,ptr(codes2),ptr(scales2))
            assert np.array_equal(codes,codes2) and np.array_equal(scales,scales2)
            mods=np.array([{'text':0,'image':1,'audio':2}.get(r[2],3) for r in old],np.uint8)
            scale=np.array([not(r[3]!='chunk' and r[6]>50 and r[4]>30) if r[5]=='pdf' else not(r[3]=='chunk' and r[4]>40) for r in old])
            a=np.empty(n,np.float32);b=np.empty_like(a)
            count=512
            for qi in np.random.default_rng(6721).choice(n,count,replace=False):
                q=np.array(v[qi],np.float32)
                lib.int8_scan(ptr(codes),ptr(scales),n,ptr(q),ptr(a))
                lib.int8_scan(ptr(codes2),ptr(scales2),n,ptr(q),ptr(b))
                assert np.array_equal(a,b)
                # Identical whole-population scores and masks prove all z-scores,
                # all gate decisions and both segment/file top-k orders, for any k.
            za=meaning(a,mods,scale);zb=meaning(b,mods,scale)
            assert np.array_equal(za,zb)
            result['policies'][policy]={'queries':count,'rows':n,'all_cosine_bits_equal':True,
                'all_z_scores_and_gates_equal_by_identical_inputs':True,'top_k_identical_for_all_k':True}
            del old,new,v,w,codes,codes2,scales,scales2
        out[variant]=result
        c.close()
        (scratch/'parity.json').write_text(json.dumps(out,indent=2))
        print(variant,'parity complete',flush=True)
    out['peak_rss_bytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    (scratch/'parity.json').write_text(json.dumps(out,indent=2))


if __name__=='__main__':main()
