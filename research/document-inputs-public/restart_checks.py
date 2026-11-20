"""Interrupt a synthetic three-page run and prove only unfinished inference repeats."""
import json
import shutil
from unittest.mock import patch

import numpy as np

import run
from durable import save_json
from guard import ROOT


class Tokens:
    def query(self,text):return [2,10,1]
    def document(self,title,text):return [2,11,1]
    def bare(self,text):return [12]


class FakeReference:
    tokens=Tokens()
    device='cpu'

    def __init__(self,fail_after=None):
        self.calls=0
        self.fail_after=fail_after

    def soft_tokens(self,*args):return np.zeros((1,512),dtype=np.float32)

    def run(self,*args):
        if self.calls==self.fail_after:raise InterruptedError('simulated interruption')
        self.calls+=1
        vector=np.zeros(768,dtype=np.float32)
        vector[0]=1
        return vector


def main():
    folder=ROOT/'restart-verification'
    if folder.exists():shutil.rmtree(folder)
    folder.mkdir()
    state={'name':folder.name,'pages':[{'id':str(i),'title':'test','doc':'test'} for i in range(3)],
           'queries':{'q':'test'},'revision':'synthetic-check-only'}
    def page_inputs(page,folder):
        image=folder/'current.jpg'
        image.touch()
        return np.zeros((48,48,3),dtype=np.uint8),'test',image
    prep=(np.zeros((1,9,768),dtype=np.float32),np.zeros((1,9,2),dtype=np.int64),1,np.zeros((48,48,3),dtype=np.uint8))
    try:
        with patch.object(run,'prepare',return_value=state),patch.object(run,'page_inputs',side_effect=page_inputs),patch.object(run,'prepare_image',return_value=prep):
            interrupted=FakeReference(fail_after=11)
            try:run.embed_subset(interrupted,folder.name,3)
            except InterruptedError:pass
            else:raise AssertionError('simulation did not interrupt')
            assert len(list((folder/'page-checkpoints').glob('*.npz')))==2
            (folder/'page-checkpoints/00002.npz.part').write_bytes(b'incomplete checkpoint')
            resumed=FakeReference()
            _,vectors,queries,inputs=run.embed_subset(resumed,folder.name,3)
            assert resumed.calls==5,'finished pages or query were recomputed'
            assert len(inputs)==3 and queries.shape==(1,768)
            for v in vectors.values():assert np.isfinite(v).all()
            run.embed_subset(None,folder.name,3)
        result={'status':'passed','completed_pages_surviving_interruption':2,'unfinished_pages':1,
                'inference_calls_after_restart':resumed.calls,'expected_calls_after_restart':5,
                'completed_query_skipped':True,'partial_file_ignored':True,'completed_subset_skipped_without_model':True,
                'note':'Synthetic persistence check only. No accuracy measurements or model inference.'}
        save_json(run.HERE/'restart-checks.json',result)
        print(json.dumps(result,indent=2))
    finally:
        shutil.rmtree(folder)


if __name__=='__main__':main()
