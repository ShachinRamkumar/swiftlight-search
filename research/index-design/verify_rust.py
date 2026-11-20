#!/usr/bin/env python3
"""Compare the actual extracted Rust kernels to the offline C/Python replicas."""
import ctypes
import json
from pathlib import Path
import subprocess
import numpy as np
from study import ROOT,connect
from vectors import collect,ptr,meaning


def extract(source,name):
    start=source.index('fn '+name+'(')
    brace=source.index('{',start)
    depth=1;end=brace+1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    source=(ROOT.parents[1]/'backend/src/semantic.rs').read_text()
    code='const DIM:usize=768;\n'+extract(source,'quantize')+'\n'+extract(source,'dot_rows')+'\n'
    code+='#[cfg(target_arch="aarch64")]\n#[target_feature(enable="dotprod")]\nunsafe '+extract(source,'dot_rows_neon')+'\n'
    code+=extract(source,'meaning')+'\n'
    code+='''fn floats(b:&[u8])->Vec<f32>{b.chunks_exact(4).map(|v|f32::from_le_bytes(v.try_into().unwrap())).collect()}
fn main(){
 let p=std::env::args().nth(1).unwrap();
 let codes:Vec<i8>=std::fs::read(format!("{p}/verify.codes")).unwrap().iter().map(|b|*b as i8).collect();
 let scales=floats(&std::fs::read(format!("{p}/verify.scales")).unwrap());
 let queries=floats(&std::fs::read(format!("{p}/verify.queries")).unwrap());
 let mods=std::fs::read(format!("{p}/verify.mods")).unwrap();
 let mask=std::fs::read(format!("{p}/verify.mask")).unwrap();
 let mut output=Vec::new();
 for q in queries.chunks_exact(DIM){
  let mut qc=Vec::new();let unit=quantize(q,&mut qc);let mut dots=vec![0;scales.len()];
  dot_rows(&codes,&qc,&mut dots);
  let scores:Vec<f32>=dots.iter().zip(&scales).map(|(&d,&u)|d as f32*u*unit).collect();
  let z=meaning(&scores,&mods,|r|mask[r]!=0);
  for v in scores{output.extend_from_slice(&v.to_le_bytes());}
  for v in z{output.extend_from_slice(&v.to_le_bytes());}
 }
 std::fs::write(format!("{p}/verify.output"),output).unwrap();
}'''
    (scratch/'verify.rs').write_text(code)
    subprocess.run(['rustc','--edition','2024','-O',str(scratch/'verify.rs'),'-o',str(scratch/'verify-rust')],check=True)
    c=connect(scratch/'baseline.sqlite');records=collect(c,'coreai-all');n=len(records)
    v=np.memmap(scratch/'coreai-all.fp16',mode='r',dtype='<f2',shape=(n,768))
    codes=np.empty((n,768),np.int8);scales=np.empty(n,np.float32)
    lib=ctypes.CDLL(str(scratch/'scan.dylib'))
    lib.make_codes.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    lib.int8_scan.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p]
    lib.make_codes(ptr(v),n,ptr(codes),ptr(scales))
    mods=np.array([{'text':0,'image':1,'audio':2}.get(r[2],3) for r in records],np.uint8)
    mask=np.array([not(r[3]!='chunk' and r[6]>50 and r[4]>30) if r[5]=='pdf' else not(r[3]=='chunk' and r[4]>40) for r in records],np.uint8)
    queries=np.array(v[np.random.default_rng(6721).choice(n,32,replace=False)],np.float32)
    for name,data in (('codes',codes),('scales',scales),('mods',mods),('mask',mask),('queries',queries)):
        (scratch/('verify.'+name)).write_bytes(data.tobytes())
    subprocess.run([str(scratch/'verify-rust'),str(scratch)],check=True)
    raw=(scratch/'verify.output').read_bytes();stride=n*12;maximum=0.;exact_scores=True;exact_z=True
    score=np.empty(n,np.float32)
    for i,q in enumerate(queries):
        start=i*stride
        a=np.frombuffer(raw,dtype='<f4',count=n,offset=start)
        z=np.frombuffer(raw,dtype='<f8',count=n,offset=start+n*4)
        lib.int8_scan(ptr(codes),ptr(scales),n,ptr(q),ptr(score))
        other=meaning(score,mods,mask.astype(bool))
        exact_scores &= np.array_equal(a,score)
        exact_z &= np.array_equal(z,other)
        maximum=max(maximum,float(np.max(np.abs(z-other))))
    out={'queries':32,'rows':n,'c_scores_bit_identical_to_actual_rust':bool(exact_scores),
         'python_z_scores_bit_identical_to_actual_rust':bool(exact_z),'maximum_z_error':maximum}
    (scratch/'rust-parity.json').write_text(json.dumps(out,indent=2))
    assert exact_scores and exact_z,out
    print('Actual Rust scoring kernels match offline replicas bit for bit')


if __name__=='__main__':main()
