#!/usr/bin/env python3
"""Assemble a verified offline runtime with APFS copy-on-write clones."""
import argparse, hashlib, json, os, shutil, subprocess, uuid
from pathlib import Path
KEY = "coreai-eg2-text-v1"
WEIGHTS = "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79"
PINNED = {
 "token-table.bf16": "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877",
 "tokenizer.json": "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4",
 "tokenizer_config.json": "17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874",
 "rope-tables/sha256.json": "db6717acee35098dde0ef9ad8523357b3cf0862dd7835892ff80b87aa434bab4",
 "text-query.aimodel": "5458d39566702585a3d4df182ce8df79ff21e1d9be0203d58f4dd975cd514da8",
 "text-doc.aimodel": "5f94157acada7ce1f93c48f6aca1606bee9076338a6e31ba7402f9661cc54cf1",
}
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024), b''): h.update(b)
 return h.hexdigest()
def verify(folder, manifest):
 actual={str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file() and p.name not in ('manifest.json','fingerprint.json','option-a.json')}
 if actual!=set(manifest['files']): raise RuntimeError('runtime file list differs')
 for name, expected in manifest['files'].items():
  if (folder/name).is_symlink() or not (folder/name).is_file(): raise RuntimeError('not a regular runtime file: '+name)
  if sha(folder/name)!=expected: raise RuntimeError('SHA-256 mismatch: '+name)
def fingerprint(folder, manifest):
 files={}
 for name in sorted(manifest['files']):
  st=(folder/name).stat()
  files[name]={'size':st.st_size,'st_mtime_ns':st.st_mtime_ns,'st_ino':st.st_ino}
 record={'manifest_sha256':sha(folder/'manifest.json'),'files':files}
 temporary=folder/('.fingerprint-'+uuid.uuid4().hex+'.writing')
 try:
  with temporary.open('x') as f:
   json.dump(record,f,indent=2,sort_keys=True);f.write('\n');f.flush();os.fsync(f.fileno())
  os.replace(temporary,folder/'fingerprint.json')
 finally:
  if temporary.exists():temporary.unlink()
def _stage_base(stage_root=None):
 root_value=stage_root or os.environ.get('SWIFTLIGHT_MODEL_STAGE_ROOT')
 if not root_value: raise RuntimeError('set SWIFTLIGHT_MODEL_STAGE_ROOT to the local Core AI export workspace')
 return Path(root_value).expanduser().absolute()
def install(dest, stage_root=None):
 dest=dest.expanduser().absolute()
 if dest.name!=KEY: raise RuntimeError('destination must be named '+KEY)
 base=_stage_base(stage_root); out=base/'output/coreai-port'; tmp=base/'tmp/coreai-port'
 sources={
  'text-query.aimodel':tmp/'p2-assets/text-query.aimodel',
  'text-doc.aimodel':tmp/'p2-assets/text-doc.aimodel',
  'token-table.bf16':out/'p1/token-table.bf16',
  'tokenizer.json':base/'tmp/eg2-hf/tokenizer.json',
  'tokenizer_config.json':base/'tmp/eg2-hf/tokenizer_config.json',
  'rope-tables':out/'p3a/rope-tables',
  'p2-manifest.json':out/'p2/manifest.json',
 }
 p2=json.loads(sources['p2-manifest.json'].read_text())
 if p2['checkpoint']['sha256']!=WEIGHTS: raise RuntimeError('checkpoint identity differs')
 files={}
 for name, source in sources.items():
  for file in (sorted(source.rglob('*')) if source.is_dir() else [source]):
   if file.is_file():files[name+('/'+str(file.relative_to(source)) if source.is_dir() else '')]=sha(file)
 for name, expected in PINNED.items():
  if not name.endswith('.aimodel') and files[name]!=expected:raise RuntimeError('source SHA-256 mismatch: '+name)
 for name, expected in json.loads(sources['rope-tables'].joinpath('sha256.json').read_text()).items():
  if files['rope-tables/'+name]!=expected:raise RuntimeError('source SHA-256 mismatch: rope-tables/'+name)
 assets=[]
 for asset in p2['production_assets']:
  name=Path(asset['path']).name
  if name not in ('text-query.aimodel','text-doc.aimodel'):raise RuntimeError('unexpected asset '+name)
  for file in asset['files']:
   if files[name+'/'+file['path']]!=file['sha256']:raise RuntimeError('asset SHA-256 mismatch: '+name+'/'+file['path'])
  digest=hashlib.sha256(json.dumps(asset['files'],sort_keys=True,separators=(',',':')).encode()).hexdigest()
  if digest!=PINNED[name] or asset['sha256']!=digest:raise RuntimeError('asset identity mismatch: '+name)
  assets.append({'path':name,'sha256':digest})
 manifest={'model_key':KEY,'checkpoint':{'model':'google/embeddinggemma-2','revision':'914f7f8','sha256':WEIGHTS},
  'host_prep':'p3a-bf16-fp32scale-shipped-rope-v1','host_prep_source_sha256':p2['p1_sha256']['host.py'],
  'tokenizer':{'crate':'0.23.2','python_reference':'0.23.3','sha256':files['tokenizer.json']},
  'production_assets':assets,'files':dict(sorted(files.items()))}
 if dest.exists():
  if json.loads((dest/'manifest.json').read_text())!=manifest:raise RuntimeError('refusing overwrite: manifest differs: '+str(dest))
  verify(dest,manifest);fingerprint(dest,manifest);return manifest
 dest.parent.mkdir(parents=True,exist_ok=True)
 stage=dest.with_name('.'+KEY+'.install-'+uuid.uuid4().hex);stage.mkdir()
 try:
  for name, source in sources.items():subprocess.run(['cp','-cR',str(source),str(stage/name)],check=True)
  verify(stage,manifest)
  (stage/'manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
  fingerprint(stage,manifest)
  stage.rename(dest)
 except BaseException:
  shutil.rmtree(stage);raise
 return manifest

def install_vision(dest, text_runtime, host_tables):
 dest=dest.expanduser().absolute()
 if dest.name!='coreai-eg2-v1':raise RuntimeError('destination must be named coreai-eg2-v1')
 text=json.loads((text_runtime/'manifest.json').read_text());verify(text_runtime,text)
 if text['model_key']!=KEY or text['checkpoint']['sha256']!=WEIGHTS:raise RuntimeError('text identity mismatch')
 base=_stage_base(); stage_b=base/'output/coreai-port/p4/manifest-stageB.json'
 vision=json.loads(stage_b.read_text())['vision']
 host=json.loads((host_tables/'identity.json').read_text())
 for name,digest in host['files'].items():
  if sha(host_tables/name)!=digest:raise RuntimeError('host table identity mismatch: '+name)
 for name,entry in vision['files'].items():
  if sha(Path(vision['path'])/name)!=entry['sha256']:raise RuntimeError('vision asset mismatch: '+name)
 manifest=dict(text);manifest['model_key']='coreai-eg2-v1'
 manifest['text_identity']={key:text[key] for key in ['checkpoint','host_prep','host_prep_source_sha256','tokenizer','production_assets']}
 manifest['vision_identity']={'asset_sha256':vision['sha256'],'stage_b_manifest_sha256':sha(stage_b),'host':host}
 manifest['production_assets']=text['production_assets']+[{'path':'vision.aimodel','sha256':vision['sha256']}]
 files=dict(text['files'])
 files.update({'vision.aimodel/'+name:entry['sha256'] for name,entry in vision['files'].items()})
 files.update({'vision-host/'+p.name:sha(p) for p in host_tables.iterdir() if p.is_file()})
 files['p4-manifest.json']=sha(stage_b)
 manifest['files']=dict(sorted(files.items()))
 if dest.exists():
  if json.loads((dest/'manifest.json').read_text())!=manifest:raise RuntimeError('refusing overwrite: manifest differs')
  verify(dest,manifest);fingerprint(dest,manifest);return manifest
 stage=dest.with_name('.coreai-eg2-v1.install-'+uuid.uuid4().hex);stage.mkdir()
 try:
  for name in sorted(text_runtime.iterdir()):
   if name.name not in ('manifest.json','fingerprint.json'):subprocess.run(['cp','-cR',str(name),str(stage/name.name)],check=True)
  for src,name in [(Path(vision['path']),'vision.aimodel'),(host_tables,'vision-host'),(stage_b,'p4-manifest.json')]:
   subprocess.run(['cp','-cR',str(src),str(stage/name)],check=True)
  verify(stage,manifest)
  (stage/'manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
  fingerprint(stage,manifest);stage.rename(dest)
 except BaseException:
  shutil.rmtree(stage);raise
 return manifest

def install_audio(dest, host_tables):
 dest=dest.expanduser().absolute()
 if dest.name!='coreai-eg2-v1':raise RuntimeError('audio requires coreai-eg2-v1')
 old=json.loads((dest/'manifest.json').read_text());verify(dest,old)
 if old['model_key']!='coreai-eg2-v1' or 'vision_identity' not in old:raise RuntimeError('audio requires verified text/image runtime')
 base=_stage_base(); stage_b=base/'output/coreai-port/p5/manifest-stageB.json'
 accepted=json.loads(stage_b.read_text())
 if accepted['audio_asset_version']!='v2' or not accepted['production_accepted']:raise RuntimeError('expected accepted audio v2')
 asset=base/'tmp/coreai-port/p5-assets/audio.aimodel'
 entries={str(p.relative_to(asset)):{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(asset.rglob('*')) if p.is_file()}
 digest=hashlib.sha256(json.dumps(entries,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 if digest!='543ad8ce6f740e2e7c185f67471ccc62be67a319d3d50c25650a8a66873b036c':raise RuntimeError('audio v2 asset mismatch')
 host=json.loads((host_tables/'identity.json').read_text())
 for name,value in host['files'].items():
  if sha(host_tables/name)!=value:raise RuntimeError('audio host hash mismatch: '+name)
 manifest=dict(old)
 manifest['audio_identity']={'asset_sha256':digest,'stage_b_manifest_sha256':sha(stage_b),'host':host}
 manifest['production_assets']=[a for a in old['production_assets'] if a['path']!='audio.aimodel']+[{'path':'audio.aimodel','sha256':digest}]
 files=dict(old['files']);files.update({'audio.aimodel/'+name:entry['sha256'] for name,entry in entries.items()})
 files.update({'audio-host/'+p.name:sha(p) for p in host_tables.iterdir() if p.is_file()});files['p5-manifest.json']=sha(stage_b)
 manifest['files']=dict(sorted(files.items()))
 if 'audio_identity' in old:
  if old!=manifest:raise RuntimeError('refusing changed audio runtime identity')
  verify(dest,manifest);fingerprint(dest,manifest);return manifest
 stage=dest.with_name('.audio.install-'+uuid.uuid4().hex);stage.mkdir()
 try:
  for src,name in [(asset,'audio.aimodel'),(host_tables,'audio-host'),(stage_b,'p5-manifest.json')]:
   subprocess.run(['cp','-cR',str(src),str(stage/name)],check=True)
  for name in ('audio.aimodel','audio-host','p5-manifest.json'):
   if (dest/name).exists():raise RuntimeError('unexpected existing audio file: '+name)
  for name in ('audio.aimodel','audio-host','p5-manifest.json'):(stage/name).rename(dest/name)
  verify(dest,manifest)
  temporary=dest/('.manifest-'+uuid.uuid4().hex)
  temporary.write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n');os.replace(temporary,dest/'manifest.json')
  fingerprint(dest,manifest)
 finally:shutil.rmtree(stage)
 return manifest

def install_video(dest, host):
 dest=dest.expanduser().absolute();old=json.loads((dest/'manifest.json').read_text());verify(dest,old)
 if old['model_key']!='coreai-eg2-v1' or 'audio_identity' not in old:raise RuntimeError('video requires the accepted combined runtime')
 files={p.name:sha(p) for p in host.iterdir() if p.is_file()}
 identity=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 manifest=dict(old);manifest['video_identity']=identity
 manifest['files']=dict(sorted({**old['files'],**{'video-host/'+k:v for k,v in files.items()}}.items()))
 if 'video_identity' in old:
  if manifest!=old:raise RuntimeError('video identity changed')
 else:
  subprocess.run(['cp','-cR',str(host),str(dest/'video-host')],check=True)
  verify(dest,manifest)
  temp=dest/('.manifest-'+uuid.uuid4().hex);temp.write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n');os.replace(temp,dest/'manifest.json')
 fingerprint(dest,manifest);return manifest

def install_runtime(dest, source):
 """Install the completed combined runtime beside Models, with final-destination fingerprints."""
 dest=dest.expanduser().absolute();source=source.expanduser().resolve()
 manifest=json.loads((source/'manifest.json').read_text())
 if manifest.get('verification_only'):raise RuntimeError('verification-only staging cannot be installed as a production runtime')
 if dest.name!='coreai-eg2-v1' or manifest['model_key']!='coreai-eg2-v1':raise RuntimeError('expected combined runtime')
 if not all(k in manifest for k in (('vision_identity','video_identity') if manifest.get('storage_layout') in ('option-a-v1','single-model-v2') else ('vision_identity','audio_identity','video_identity'))):raise RuntimeError('runtime lacks a modality')
 expected={'q32':'function-assets/q32.aimodel','q64':'function-assets/query-rest.aimodel','q128':'function-assets/query-rest.aimodel',
           'v1260':'function-assets/v1260.aimodel','v630':'function-assets/vision-rest.aimodel','v2520':'function-assets/vision-rest.aimodel'}
 if manifest.get('storage_layout') not in ('option-a-v1','single-model-v2') and manifest.get('function_assets')!=expected:raise RuntimeError('production runtime requires the verified P7 recovery partitions')
 if manifest['checkpoint']['sha256']!=WEIGHTS:raise RuntimeError('checkpoint identity differs')
 verify(source,manifest)
 if dest.exists():
  if json.loads((dest/'manifest.json').read_text())!=manifest:raise RuntimeError('refusing overwrite: installed runtime differs')
  verify(dest,manifest);fingerprint(dest,manifest);return manifest
 dest.parent.mkdir(parents=True,exist_ok=True)
 stage=dest.with_name('.coreai-eg2-v1.install-'+uuid.uuid4().hex)
 try:
  subprocess.run(['cp','-cR',str(source),str(stage)],check=True)
  verify(stage,manifest)
  stage.rename(dest)
  fingerprint(dest,manifest)
 except BaseException:
  if stage.exists():shutil.rmtree(stage)
  raise
 return manifest

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--video-host',type=Path);parser.add_argument('--dest',required=True,type=Path)
 parser.add_argument('--verification-staging',action='store_true',help='assemble an unapproved, research-only runtime that production loaders reject');parser.add_argument('--option-a',action='store_true');parser.add_argument('--single-model',action='store_true');parser.add_argument('--merged-model',type=Path);parser.add_argument('--download-audio',action='store_true');parser.add_argument('--merged-text',type=Path);parser.add_argument('--release-manifest',type=Path,default=Path(__file__).resolve().parents[1]/'models/CoreAI/option-a.json')
 parser.add_argument('--source-runtime',type=Path);parser.add_argument('--text-runtime',type=Path);parser.add_argument('--vision-host',type=Path);parser.add_argument('--audio-host',type=Path);args=parser.parse_args()
 if args.verification_staging and not (args.option_a or args.single_model):parser.error('--verification-staging requires --option-a or --single-model')
 if sum((args.option_a,args.single_model,args.download_audio))>1:parser.error('choose one runtime assembly mode')
 if args.single_model and args.release_manifest==Path(__file__).resolve().parents[1]/'models/CoreAI/option-a.json':args.release_manifest=Path(__file__).resolve().parents[1]/'models/CoreAI/single-model.json'
 if args.option_a or args.single_model or args.download_audio:
  import storage_option_a, sys
  if args.single_model and (not args.source_runtime or not args.merged_model):parser.error('--single-model requires --source-runtime and --merged-model')
  if args.option_a and (not args.source_runtime or not args.merged_text):parser.error('--option-a requires --source-runtime and --merged-text')
  manifest=storage_option_a.install(args.dest,args.source_runtime,args.merged_model if args.single_model else args.merged_text,args.release_manifest,sys.modules[__name__],verification_staging=args.verification_staging,single=args.single_model) if (args.option_a or args.single_model) else storage_option_a.download_audio(args.dest,args.release_manifest,sys.modules[__name__])
 else: manifest=install_runtime(args.dest,args.source_runtime) if args.source_runtime else install_video(args.dest,args.video_host) if args.video_host else install_audio(args.dest,args.audio_host) if args.audio_host else (install_vision(args.dest,args.text_runtime,args.vision_host) if args.vision_host else install(args.dest))
 print(json.dumps({'runtime':str(args.dest),'files_verified':len(manifest['files']),'model_key':manifest['model_key']}))
