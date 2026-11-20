#!/usr/bin/env python3
import ctypes
import json
from pathlib import Path
import subprocess
import time
import numpy as np
from study import ROOT,connect
from vectors import collect,ptr,meaning


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    subprocess.run(['clang','-O3','-march=armv8.4-a+dotprod','-ffp-contract=off','-shared',
                    '-o',str(scratch/'binary.dylib'),str(ROOT/'scan.c')],check=True)
    lib=ctypes.CDLL(str(scratch/'binary.dylib'))
    lib.binary_scan.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    lib.half_scan.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    c=connect(scratch/'baseline.sqlite');rows=collect(c,'coreai-all');n=len(rows)
    v=np.memmap(scratch/'coreai-all.fp16',mode='r',dtype='<f2',shape=(n,768))
    bits=np.packbits(np.signbit(v),axis=1)
    mods=np.array([{'text':0,'image':1,'audio':2}.get(r[2],3) for r in rows],np.uint8)
    mask=np.array([not(r[3]!='chunk' and r[6]>50 and r[4]>30) if r[5]=='pdf' else not(r[3]=='chunk' and r[4]>40) for r in rows])
    a=np.empty(n,np.float32);b=np.empty_like(a);times=[]
    misses={str(k):0 for k in (20,64,256,1024)};flips=np.zeros(3,np.int64)
    for qi in np.random.default_rng(6721).choice(n,128,replace=False):
        q=np.array(v[qi],np.float32)
        lib.half_scan(ptr(v),n,ptr(q),ptr(a))
        start=time.perf_counter();lib.binary_scan(ptr(bits),n,ptr(bits[qi]),ptr(b))
        times.append((time.perf_counter()-start)*1000)
        exact=meaning(a,mods,mask);binary=meaning(b,mods,mask)
        truth=set(np.argsort(-exact,kind='stable')[:20]);order=np.argsort(-binary,kind='stable')
        for k in misses:misses[k]+=int(not truth.issubset(order[:int(k)]))
        flips+=[np.count_nonzero((exact>=g)!=(binary>=g)) for g in (4.5,2.5,3.)]
    out={'queries':128,'rows':n,'sign_bytes':bits.nbytes,'median_ms':float(np.median(times)),
         'p95_ms':float(np.percentile(times,95)),'top20_miss_queries_by_candidate_count':misses,
         'gate_flips':flips.tolist()}
    (scratch/'binary.json').write_text(json.dumps(out,indent=2));print('binary prefilter complete',flush=True)


if __name__=='__main__':main()
