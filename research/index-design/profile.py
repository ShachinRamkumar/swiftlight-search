#!/usr/bin/env python3
"""Fresh-process, warm-filesystem startup and steady-state RSS comparisons."""
import ctypes
import json
from pathlib import Path
import resource
import subprocess
import sys
import time
import numpy as np
from study import connect, ROOT
from vectors import ptr

SCRATCH=Path.home()/'.swiftlight-research/index-design'


def child(mode):
    lib=ctypes.CDLL(str(SCRATCH/'scan.dylib'))
    lib.make_codes.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    lib.int8_scan.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    lib.half_scan_f32.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    before=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    start=time.perf_counter()
    n=26599
    direct=mode.endswith('-direct')
    base_mode=mode.removesuffix('-direct')
    if base_mode in ('sqlite','compact','reference','compressed'):
        path={'sqlite':'baseline.sqlite','compact':'backend-compacted.sqlite',
              'reference':'fts-reference-external.sqlite','compressed':'fts-compressed-external.sqlite'}[base_mode]
        c=connect(SCRATCH/path)
        n=c.execute('SELECT count(*) FROM vectors WHERE model=2').fetchone()[0]
        codes=np.empty((n,768),np.int8);scales=np.empty(n,np.float32)
        sql="""WITH model_vectors AS MATERIALIZED (SELECT segment,vec FROM vectors WHERE model=2)
            SELECT v.vec FROM model_vectors v JOIN segments s ON s.id=v.segment
            JOIN files f ON f.id=s.file WHERE s.modality IN ('text','image') ORDER BY v.segment"""
        if direct:
            sql="""SELECT v.vec FROM vectors v JOIN segments s ON s.id=v.segment
                JOIN files f ON f.id=s.file WHERE v.model=2 AND s.modality IN ('text','image') ORDER BY v.segment"""
        for i,(blob,) in enumerate(c.execute(sql)):
            v=np.frombuffer(blob,dtype='<f2')
            lib.make_codes(ptr(v),1,ptr(codes[i]),ctypes.c_void_p(scales.ctypes.data+4*i))
        query=np.array(v,dtype=np.float32)
    else:
        v=np.memmap(SCRATCH/'coreai-all.fp16',mode='r',dtype='<f2',shape=(n,768))
        query=np.array(v[0],np.float32)
        if mode=='mmap-int8':
            codes=np.empty((n,768),np.int8);scales=np.empty(n,np.float32)
            lib.make_codes(ptr(v),n,ptr(codes),ptr(scales))
    startup=(time.perf_counter()-start)*1000
    out=np.empty(n,np.float32)
    times=[]
    for _ in range(40):
        start=time.perf_counter()
        if mode=='mmap-fp16':lib.half_scan_f32(ptr(v),n,ptr(query),ptr(out))
        else:lib.int8_scan(ptr(codes),ptr(scales),n,ptr(query),ptr(out))
        times.append((time.perf_counter()-start)*1000)
    peak=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    print(json.dumps({'startup_ms':startup,'peak_rss_bytes':peak,'interpreter_import_peak_bytes':before,
                      'increase_bytes':peak-before,'scan_median_ms':float(np.median(times)),
                      'scan_p95_ms':float(np.percentile(times,95))}))


def main():
    out={}
    for mode in ('sqlite','compact','compressed','reference','sqlite-direct','compact-direct','reference-direct','mmap-int8','mmap-fp16'):
        samples=[json.loads(subprocess.check_output([sys.executable,str(ROOT/'profile.py'),mode])) for _ in range(5)]
        out[mode]={k:float(np.median([s[k] for s in samples])) for k in samples[0]}
        out[mode]['fresh_processes']=5
        (SCRATCH/'profile.json').write_text(json.dumps(out,indent=2))
        print(mode,'complete',flush=True)


if __name__=='__main__':
    child(sys.argv[1]) if len(sys.argv)>1 else main()
