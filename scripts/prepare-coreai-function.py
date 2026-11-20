#!/usr/bin/env python3
"""Derive one single-entrypoint source asset without changing its retained graph.

Run during verified runtime installation, before publishing the runtime. No inference,
conversion, precision rewrite, network access or cache-file operations occur here.
"""
import argparse, hashlib, importlib.util, json, os, shutil, uuid
from pathlib import Path

FUNCTIONS = {'q32':'text-query','q64':'text-query','q128':'text-query',
 'd256':'text-doc','d512':'text-doc','d1024':'text-doc','d2048':'text-doc',
 'v630':'vision','v1260':'vision','v2520':'vision','a3000':'audio'}
PARTITIONS = {'q32': ['q32'], 'query-rest': ['q64','q128'],
              'v1260': ['v1260'], 'vision-rest': ['v630','v2520']}

def prepare(runtime, function):
 spec=importlib.util.spec_from_file_location('coreai_runtime_install',Path(__file__).with_name('install-coreai-runtime.py'))
 installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
 manifest=json.loads((runtime/'manifest.json').read_text())
 if manifest.get('storage_layout') == 'single-model-v2' and not (runtime/'EmbeddingGemma2.aimodel').is_dir():
  raise RuntimeError('source-free single model: use digup prepare-runtime to validate its bookmark or download its pinned source')
 installer.verify(runtime,manifest)
 relative='function-assets/'+function+'.aimodel';destination=runtime/relative
 retained_functions = PARTITIONS.get(function, [function])
 if manifest.get('storage_layout') == 'single-model-v2':
  return dict(function=function,reused=True,asset=str(runtime/'EmbeddingGemma2.aimodel'),note='All text, vision and audio functions share the retained single model.')
 if manifest.get('storage_layout') == 'option-a-v1':
  tower = FUNCTIONS[retained_functions[0]]
  name = 'text.aimodel' if tower.startswith('text-') else tower + '.aimodel'
  if not any(a['path'] == name for a in manifest['production_assets']):raise RuntimeError('optional source is not installed: ' + name)
  return dict(function=function,reused=True,asset=str(runtime/name),note='Option A keeps all entrypoints in one retained source per tower.')
 if all(name in manifest.get('function_assets',{}) for name in retained_functions):
  if any(manifest['function_assets'][name]!=relative for name in retained_functions):raise RuntimeError('function mapping differs')
  installer.fingerprint(runtime,manifest)
  return dict(function=function,reused=True,asset=str(destination))
 source_name = FUNCTIONS[retained_functions[0]]
 source=runtime/(source_name+'.aimodel')
 if function=='a3000':
  return dict(function=function,reused=True,asset=str(source),note='Audio already has exactly one entrypoint; no duplicate asset is needed.')
 # The authoring SDK is needed only by this offline installation step.
 from coreai.authoring import AIProgram
 program=AIProgram._load_bytecode(source/'main.mlirb')
 graphs=[c.operation for c in program._module._mlir_module.body.operations if c.operation.name=='coreai.graph']
 chosen=[op for op in graphs if str(op.attributes['sym_name']).strip('"') in retained_functions]
 if len(chosen)!=len(retained_functions):raise RuntimeError('source does not contain requested graphs')
 removed=[]
 for op in graphs:
  name=str(op.attributes['sym_name']).strip('"')
  if name not in retained_functions:removed.append(name);op.erase()
 retained=[str(c.operation.attributes['sym_name']).strip('"') for c in program._module._mlir_module.body.operations if c.operation.name=='coreai.graph']
 if set(retained)!=set(retained_functions):raise RuntimeError('unexpected graph set after removing siblings')
 stage=runtime.parent/('.function-'+function+'-'+uuid.uuid4().hex+'.aimodel')
 try:
  program.save_asset(stage)
  files={relative+'/'+str(p.relative_to(stage)):installer.sha(p) for p in stage.rglob('*') if p.is_file()}
  if not {'main.mlirb','main.hash','metadata.json'}.issubset({p.name for p in stage.iterdir()}):raise RuntimeError('incomplete function asset')
  destination.parent.mkdir(exist_ok=True)
  if destination.exists():raise RuntimeError('refusing an unregistered existing function asset')
  stage.rename(destination)
  manifest['files'].update(files)
  for name in retained_functions:manifest.setdefault('function_assets',{})[name]=relative
  manifest.setdefault('function_derivation',{})[function]=dict(source=source_name+'.aimodel',source_sha256=manifest['files'][source_name+'.aimodel/main.mlirb'],rule='remove-sibling-coreai.graph-v1',removed=removed,retained=retained)
  temporary=runtime/('.manifest-'+uuid.uuid4().hex)
  temporary.write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
  os.replace(temporary,runtime/'manifest.json')
  installer.verify(runtime,manifest);installer.fingerprint(runtime,manifest)
  return dict(function=function,reused=False,asset=str(destination),bytes=sum(p.stat().st_size for p in destination.rglob('*') if p.is_file()),files=files,removed=removed)
 finally:
  if stage.exists():shutil.rmtree(stage)

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--runtime',required=True,type=Path)
 parser.add_argument('--function',required=True,choices=sorted(FUNCTIONS.keys() | PARTITIONS.keys()))
 args=parser.parse_args()
 print(json.dumps(prepare(args.runtime.expanduser().absolute(),args.function)))
