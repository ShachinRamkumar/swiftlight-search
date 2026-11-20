#!/usr/bin/env python3
"""Bounded-memory vector storage/scoring experiments on the private snapshot."""
import argparse
from compression import zstd
import ctypes
import json
import math
import mmap
from pathlib import Path
import resource
import subprocess
import time
import zlib

import numpy as np

from study import ROOT, guard, connect, timer


def meaning(scores, modality, scale):
    # Preserve Rust f64 iteration order, including the scale-only population.
    sums = [0.] * 4
    counts = [0] * 4
    all_sum = 0.
    total = 0
    for s, m, use in zip(scores, modality, scale):
        if use:
            sums[m] += float(s)
            counts[m] += 1
            all_sum += float(s)
            total += 1
    means = np.array([sums[m]/counts[m] if counts[m] >= 20 else all_sum/total for m in range(4)])
    centered = scores.astype(np.float64) - means[modality]
    mean=0.
    for x in centered[scale]:mean+=float(x)
    mean/=total
    squares=0.
    for x in centered[scale]:
        delta=float(x)-mean
        squares+=delta*delta
    return (centered-mean)/max(math.sqrt(squares/total),.02)


def ptr(a):
    return ctypes.c_void_p(a.ctypes.data)


def collect(c, mode):
    # Both supported image policies, no assumed production config.
    selected = "('text','image')" if mode == "coreai-all" else "('text')"
    return c.execute(f'''SELECT s.id,s.file,s.modality,s.kind,coalesce(s.loc,0),f.kind,
            coalesce(cast(json_extract(f.info,'$.pages') AS INTEGER),0),
            CASE WHEN s.modality IN {selected} THEN v.vec ELSE s.vec END
        FROM segments s JOIN files f ON f.id=s.file
        LEFT JOIN vectors v ON v.segment=s.id AND v.model=(SELECT id FROM embedding_models WHERE key='coreai-eg2-v1')
        WHERE f.state IN ('done','partial') AND f.indexed_at IS NOT NULL
        AND CASE WHEN s.modality IN {selected} THEN v.vec ELSE s.vec END IS NOT NULL ORDER BY s.id''').fetchall()


def parity(old, new, files, paths):
    # Ranking semantic rows and file winners, with production's path tie-break.
    order_a = np.lexsort((np.arange(len(old)), -old))[:20]
    order_b = np.lexsort((np.arange(len(new)), -new))[:20]
    gates = [int(np.count_nonzero((old>=g)!=(new>=g))) for g in (4.5,2.5,3.)]
    def file_top(scores):
        best = {}
        for f,s in zip(files,scores):
            best[f] = max(best.get(f,float('-inf')), float(s))
        return sorted(best, key=lambda f:(-best[f],paths[f]))[:20]
    return {"segment_top20_changed": int(not np.array_equal(order_a,order_b)),
            "file_top20_changed": int(file_top(old)!=file_top(new)), "gate_flips":gates,
            "max_z_error":float(np.max(np.abs(old-new)))}


def compression(c, scratch):
    rows = list(c.execute("SELECT vec FROM vectors ORDER BY model,segment"))
    raw = b''.join(r[0] for r in rows)
    output = {"rows":len(rows), "raw_bytes":len(raw)}
    for method in ("zlib", "zstd", "shuffled-zstd"):
        chunks = []
        start = time.perf_counter()
        for at in range(0,len(raw),1536*256):
            b = raw[at:at+1536*256]
            if method=="shuffled-zstd":
                b = np.frombuffer(b,dtype=np.uint8).reshape(-1,2).T.copy().tobytes()
            chunks.append(zlib.compress(b,6) if method=="zlib" else zstd.compress(b,level=3))
        encode = (time.perf_counter()-start)*1000
        def decode():
            parts = []
            for b in chunks:
                v = zlib.decompress(b) if method=="zlib" else zstd.decompress(b)
                if method=="shuffled-zstd":
                    v = np.frombuffer(v,dtype=np.uint8).reshape(2,-1).T.copy().tobytes()
                parts.append(v)
            return b''.join(parts)
        output[method] = {"bytes_including_8byte_block_offsets":sum(map(len,chunks))+8*(len(chunks)+1),
                          "encode_ms":encode, "decode":timer(decode,8), "bit_identical":decode()==raw}
    # Row compression preserves independent updates but sacrifices shared dictionary.
    for name,compress in (("zlib-row",lambda b:zlib.compress(b,6)),("zstd-row",lambda b:zstd.compress(b,level=3))):
        start=time.perf_counter()
        compressed=[compress(r[0]) for r in rows]
        output[name]={"bytes":sum(map(len,compressed)),"encode_ms":(time.perf_counter()-start)*1000}
    (scratch/"vectors.fp16").write_bytes(raw)
    output["sqlite_scan"] = timer(lambda: sum(len(r[0]) for r in c.execute("SELECT vec FROM vectors ORDER BY model,segment")),12)
    def mapped_scan():
        with open(scratch/"vectors.fp16","rb") as f, mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ) as mm:
            return sum(mm[i] for i in range(0,len(mm),16384))
    output["mmap_page_touch_only"] = timer(mapped_scan,12)
    output["sqlite_bytes"] = c.execute("SELECT sum(pgsize) FROM dbstat WHERE name='vectors'").fetchone()[0]
    # Include row identity, model, revision, modality and offset rather than comparing payload to whole-table size.
    output["packed_with_fixed_64byte_manifest_bytes"] = len(raw)+64*len(rows)
    return output


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--scratch",type=Path,default=Path.home()/".swiftlight-research/index-design")
    ap.add_argument("--queries",type=int,default=512)
    args=ap.parse_args()
    scratch=guard(args.scratch)
    subprocess.run(["clang","-O3","-march=armv8.4-a+dotprod","-ffp-contract=off","-shared","-o",str(scratch/"scan.dylib"),str(ROOT/"scan.c")],check=True)
    lib=ctypes.CDLL(str(scratch/"scan.dylib"))
    lib.make_codes.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    lib.int8_scan.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    for name in ("half_scan","half_scan_f32"):
        getattr(lib,name).argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    c=connect(scratch/"baseline.sqlite")
    out={"compression":compression(c,scratch),"scoring":{}}
    (scratch/"vectors.json").write_text(json.dumps(out,indent=2))
    for policy in ("coreai-all","coreai-text-legacy-image"):
        start=time.perf_counter()
        records=collect(c,policy)
        n=len(records)
        vector_path=scratch/(policy+".fp16")
        with vector_path.open("wb") as f:
            for r in records:f.write(r[-1])
        v=np.memmap(vector_path,mode='r',dtype='<f2',shape=(n,768))
        codes=np.empty((n,768),dtype=np.int8);scales=np.empty(n,dtype=np.float32)
        lib.make_codes(ptr(v),n,ptr(codes),ptr(scales))
        startup=(time.perf_counter()-start)*1000
        modalities=np.array([{"text":0,"image":1,"audio":2}.get(r[2],3) for r in records],dtype=np.uint8)
        scale=np.array([not (r[3]!="chunk" and r[6]>50 and r[4]>30) if r[5]=="pdf" else not(r[3]=="chunk" and r[4]>40) for r in records])
        files=np.array([r[1] for r in records]); paths=dict(c.execute("SELECT id,path FROM files"))
        qids=np.random.default_rng(6721).choice(n,min(args.queries,n),replace=False)
        a=np.empty(n,np.float32);b=np.empty(n,np.float32);fast=np.empty(n,np.float32)
        sums={"segment_top20_changed":0,"file_top20_changed":0,"gate_flips":[0,0,0],"max_z_error":0.}
        alternate={"segment_top20_changed":0,"file_top20_changed":0,"gate_flips":[0,0,0],"max_z_error":0.}
        times={"int8":[],"fp16":[],"fp16-f32":[]}
        prefilter_misses={str(k):0 for k in (20,64,256)}
        for qi in qids:
            q=np.array(v[qi],dtype=np.float32)
            for name,fn,dest in (("int8",lib.int8_scan,a),("fp16",lib.half_scan,b),("fp16-f32",lib.half_scan_f32,fast)):
                t=time.perf_counter()
                if name=="int8":fn(ptr(codes),ptr(scales),n,ptr(q),ptr(dest))
                else:fn(ptr(v),n,ptr(q),ptr(dest))
                times[name].append((time.perf_counter()-t)*1000)
            za=meaning(a,modalities,scale);zb=meaning(b,modalities,scale);zf=meaning(fast,modalities,scale)
            for totals,other in ((sums,za),(alternate,zf)):
                r=parity(zb,other,files,paths)
                for k in ("segment_top20_changed","file_top20_changed"):totals[k]+=r[k]
                totals["gate_flips"]=[x+y for x,y in zip(totals["gate_flips"],r["gate_flips"])]
                totals["max_z_error"]=max(totals["max_z_error"],r["max_z_error"])
            exact_top=set(np.argsort(-zb,kind='stable')[:20])
            approx_order=np.argsort(-za,kind='stable')
            for k in prefilter_misses:
                prefilter_misses[k]+=int(not exact_top.issubset(approx_order[:int(k)]))
        res={"rows":n,"scale_rows":int(sum(scale)),"queries":len(qids),"startup_export_and_int8_ms":startup,
             "mmap_payload_bytes":n*1536,"int8_codes_and_scales_bytes":codes.nbytes+scales.nbytes,
             "int8_vs_exact":sums,"f32_simd_vs_f64_exact":alternate,"prefilter_top20_miss_queries":prefilter_misses,
             "latency":{name:{"median_ms":float(np.median(t)),"p95_ms":float(np.percentile(t,95))} for name,t in times.items()}}
        # Byte identity of migrated storage implies the same deterministic quantization and score kernels.
        target=scratch/"fts-compressed-external.sqlite"
        if target.exists():
            migrated=connect(target)
            new_records=collect(migrated,policy)
            res["migrated_selected_rows_bit_identical"] = records==new_records
            migrated.close()
        out["scoring"][policy]=res
        out["peak_rss_bytes"]=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        (scratch/"vectors.json").write_text(json.dumps(out,indent=2))
        print(policy,"complete",flush=True)
        del records,v,codes,scales


if __name__=="__main__":main()
