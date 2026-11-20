"""Option A staging and optional audio download. Never specializes a model."""
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import uuid
from pathlib import Path
from urllib.request import urlopen
from urllib.parse import urlparse

SEMANTIC_REVISION = 'c004e85fc60e610d69de5684ae30f5e80bf091aa11ff59ad9257ed63e3ae4799'
LAYOUT = 'option-a-v1'
RESEARCH_ROOT = Path.home() / '.swiftlight-research/option-a'
MINIMUM_FREE_BYTES = 14 * 1024**3
# Set together with OptionASemanticIdentity.approvedMergedTextPackageSHA256 after bit-exact owner approval.
APPROVED_MERGED_PACKAGE_SHA256 = None
APPROVED_SINGLE_MODEL_SHA256 = 'c6bd6427f56678667897c93d57cc475c70960407d67d11e11faed4feda349ad8'
SINGLE_MODEL_LAYOUT = 'single-model-v2'
SINGLE_MODEL_ASSET = 'EmbeddingGemma2.aimodel'
GROUP_RECIPE_HASHES = {'query3': 'ca641a217029b5932bdaf576564502b18002f89e50f62110e55696bbf69e56a9', 'doc4': 'a2be7969407e8bd4121b604aeb00195edeafb8d570a9ef1cfe5ad390af893043', 'vision3': '1ba8680bdd520d6971333af9392398f58de09f32abce5ee5746912ec895a671b', 'audio1': '52013191d8894aee4b00721234654b0394eab6ce67f566971a73250fb573b553'}


def source_semantic_revision(manifest):
    vision = manifest['vision_identity']; host = vision['host']
    parts = [manifest['checkpoint']['sha256']] + sorted(a['sha256'] for a in manifest['production_assets'] if a['path'] != 'audio.aimodel')
    parts += ['p3a-bf16-fp32scale-shipped-rope-v1', vision['asset_sha256'], vision['stage_b_manifest_sha256'], host['host_sha256'], host['spec_sha256']]
    for name in sorted(host['files']): parts += [name, host['files'][name]]
    return hashlib.sha256(':'.join(parts).encode()).hexdigest()


def validate_source_semantics(manifest):
    if source_semantic_revision(manifest) != SEMANTIC_REVISION:
        raise ValueError('source semantic identity differs from accepted original')
    for name, digest in manifest['vision_identity']['host']['files'].items():
        if manifest['files'].get('vision-host/' + name) != digest:
            raise ValueError('source semantic host file binding differs')


def safe_path(root, name):
    if not isinstance(name, str) or not name or '\0' in name or any(p in ('', '.', '..') for p in name.split('/')) or name.startswith('/'):
        raise ValueError('invalid manifest path: ' + str(name))
    path = root
    for part in name.split('/'):
        path = path / part
        if path.is_symlink(): raise ValueError('symlink in manifest path: ' + name)
    return path


def checked_entry(entry):
    if not isinstance(entry.get('bytes'), int) or isinstance(entry['bytes'], bool) or entry['bytes'] <= 0 or not re.fullmatch('[a-f0-9]{64}', entry.get('sha256', '')):
        raise ValueError('release manifest still has size/SHA-256 placeholders')


def inventory(folder, sha):
    if folder.is_symlink() or not folder.is_dir(): raise ValueError('expected regular .aimodel directory')
    result = {}
    for path in sorted(folder.rglob('*')):
        if path.is_symlink(): raise ValueError('symlink in asset')
        if path.is_file(): result[str(path.relative_to(folder))] = dict(bytes=path.stat().st_size, sha256=sha(path))
    return result


def inventory_hash(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def space(folder, extra):
    if shutil.disk_usage(folder).free < MINIMUM_FREE_BYTES + extra:
        raise RuntimeError('need 14 GiB free plus staging space')


@contextlib.contextmanager
def transaction(dest, extra):
    dest = dest.expanduser().absolute()
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_symlink(): raise ValueError('runtime destination must not be a symlink')
    with (dest.parent / '.option-a-install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        space(dest.parent, extra)
        stage = dest.with_name('.' + dest.name + '.stage-' + uuid.uuid4().hex)
        try: yield dest, stage
        finally:
            if stage.exists(): shutil.rmtree(stage)


def publish(stage, dest):
    if not dest.exists(): stage.rename(dest); return
    # macOS atomically exchanges directory names. Readers see one complete generation.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-2, os.fsencode(stage), -2, os.fsencode(dest), 2) != 0:
        raise OSError(ctypes.get_errno(), 'atomic runtime exchange failed')


def write_manifest(stage, manifest, installer):
    (stage / 'fingerprint.json').unlink(missing_ok=True)
    (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    installer.verify(stage, manifest)
    installer.fingerprint(stage, manifest)


def require_research_destination(dest, *, single=False):
    resolved = dest.expanduser().resolve()
    root = ((Path.home() / '.swiftlight-research/single-model' if single else RESEARCH_ROOT) / 'staging').resolve()
    production = (Path.home() / 'Library/Application Support/Swiftlight').resolve()
    if not resolved.is_relative_to(root) or resolved.is_relative_to(production) or resolved.name != 'coreai-eg2-v1':
        raise ValueError('verification staging must stay under ' + str(root) + ' and outside production')


def install(dest, source, merged, release_file, installer, *, verification_staging=False, single=False):
    import host_tables
    if verification_staging: require_research_destination(dest, single=single)
    source, merged = source.expanduser().resolve(), merged.expanduser().resolve()
    release = json.loads(release_file.read_text())
    if release.get('format') != ('swiftlight-single-model-2' if single else 'swiftlight-option-a-1') or release.get('semantic_revision') != SEMANTIC_REVISION:
        raise ValueError('option A semantic identity mismatch')
    asset_name = SINGLE_MODEL_ASSET if single else 'text.aimodel'
    text = release['model' if single else 'text']; checked_entry(text)
    if text['path'] != asset_name: raise ValueError('expected ' + asset_name)
    for entry in text['files'].values(): checked_entry(entry)
    entries = inventory(merged, installer.sha)
    if entries != text['files'] or sum(e['bytes'] for e in entries.values()) != text['bytes'] or inventory_hash(entries) != text['sha256']:
        raise ValueError('authored text package does not match release pins')
    old = json.loads((source / 'manifest.json').read_text())
    if old['model_key'] != 'coreai-eg2-v1' or old['checkpoint']['sha256'] != installer.WEIGHTS:
        raise ValueError('expected current combined source runtime')
    validate_source_semantics(old)
    approved = APPROVED_SINGLE_MODEL_SHA256 if single else APPROVED_MERGED_PACKAGE_SHA256
    if not verification_staging and (approved is None or text['sha256'] != approved):
        raise ValueError('merged package has no matching verified approval')
    recipe_root = Path(__file__).resolve().parents[1] / 'models/CoreAI'
    if single:
        if old.get('audio_identity') != release['audio_identity']:
            raise ValueError('single model audio source identity differs')
        for name,digest in GROUP_RECIPE_HASHES.items():
            entry=release['groups'][name]['recipe'];checked_entry(entry)
            path=recipe_root/('group-'+name+'.json')
            if entry['path'] != path.name or entry['sha256']!=digest or installer.sha(path)!=digest or path.stat().st_size!=entry['bytes']:
                raise ValueError('group extraction recipe differs from release pins')
    installer.verify(source, old)
    vision_inventory = inventory(source / 'vision.aimodel', installer.sha)
    if inventory_hash(vision_inventory) != old['vision_identity']['asset_sha256']:
        raise ValueError('source semantic vision package binding differs')
    if installer.sha(source / 'rope-tables/sha256.json') != installer.PINNED['rope-tables/sha256.json']:
        raise ValueError('RoPE pin mismatch')
    with transaction(dest, 220_000_000 + text['bytes']) as (dest, stage):
        if dest.name != 'coreai-eg2-v1' or dest == source or dest in source.parents:
            raise ValueError('use a separate coreai-eg2-v1 destination')
        if dest.exists(): raise ValueError('option A assembly requires an absent destination')
        stage.mkdir()
        host_record = host_tables.pack(source, stage, installer.PINNED,
                         json.loads((source / 'rope-tables/sha256.json').read_text()), old['vision_identity']['host']['files'])
        accepted_hosts = json.loads((Path(__file__).resolve().parents[1] / 'research/storage-option-a/host-tables.json').read_text())
        if host_record != accepted_hosts:
            raise ValueError('packed host files differ from accepted lossless layout')
        copies = [(merged, asset_name), (source / 'tokenizer_config.json', 'tokenizer_config.json'), (source / 'video-host', 'video-host')]
        if single: copies += [(recipe_root/('group-'+name+'.json'),'group-'+name+'.json') for name in GROUP_RECIPE_HASHES]
        if single: copies.append((source/'audio-host','audio-host'))
        if not single: copies.append((source / 'vision.aimodel', 'vision.aimodel'))
        for src, name in copies:
            subprocess.run(['cp', '-cR', str(src), str(stage / name)], check=True)
        manifest = {k: v for k, v in old.items() if k not in ('audio_identity', 'function_assets', 'function_derivation', 'production_assets', 'files')}
        manifest.update(storage_layout=SINGLE_MODEL_LAYOUT if single else LAYOUT, semantic_revision=SEMANTIC_REVISION,
                        asset_inventory={asset_name: entries, **({} if single else {'vision.aimodel': vision_inventory})},
                        production_assets=[dict(path=asset_name, sha256=text['sha256'])] + ([] if single else [a for a in old['production_assets'] if a['path'] == 'vision.aimodel']))
        if single:
            manifest['source_download']=release['source_download']
            manifest['audio_identity']=release['audio_identity']
        if verification_staging:
            manifest['verification_only'] = True
            manifest['candidate_semantic_revision'] = manifest.pop('semantic_revision')
        manifest['files'] = {str(p.relative_to(stage)): installer.sha(p) for p in sorted(stage.rglob('*')) if p.is_file()}
        write_manifest(stage, manifest, installer)
        publish(stage, dest)
    return manifest


def download_audio(dest, release_file, installer):
    release = json.loads(release_file.read_text())
    if release.get('format') != 'swiftlight-option-a-1': raise ValueError('unknown audio release format')
    audio = release['audio']; files = audio['files']
    required = {'audio.aimodel/main.mlirb', 'audio.aimodel/main.hash', 'audio.aimodel/metadata.json',
                'audio-host/window.f32', 'audio-host/mel-bank.f32', 'audio-host/mel-bank.f64', 'audio-host/positions.f32', 'audio-host/identity.json'}
    if set(files) != required: raise ValueError('audio download file set differs')
    for name, entry in files.items():
        safe_path(Path('/unused'), name); checked_entry(entry)
        url = urlparse(entry['url'])
        if url.scheme != 'https' or not url.netloc or 'PLACEHOLDER' in entry['url']:
            raise ValueError('fill every audio file URL with an HTTPS download URL')
    model_files = {n.split('/', 1)[1]: {k: e[k] for k in ('bytes', 'sha256')} for n, e in files.items() if n.startswith('audio.aimodel/')}
    if inventory_hash(model_files) != audio['identity']['asset_sha256']:
        raise ValueError('audio model inventory differs from semantic identity')
    for name, digest in audio['identity']['host']['files'].items():
        if files.get('audio-host/' + name, {}).get('sha256') != digest:
            raise ValueError('audio host pin differs from semantic identity')
    with transaction(dest, sum(e['bytes'] for e in files.values())) as (dest, stage):
        old = json.loads((dest / 'manifest.json').read_text())
        if old.get('verification_only') is True:
            require_research_destination(dest)
            if old.get('candidate_semantic_revision') != SEMANTIC_REVISION: raise ValueError('staging identity differs')
        elif old.get('semantic_revision') != SEMANTIC_REVISION:
            raise ValueError('optional audio requires option A')
        if old.get('storage_layout') != LAYOUT: raise ValueError('optional audio requires option A')
        installer.verify(dest, old)
        pins = {name: e['sha256'] for name, e in files.items()}
        if 'audio_identity' in old:
            if old['audio_identity'] != audio['identity'] or any(old['files'].get(n) != h for n, h in pins.items()):
                raise ValueError('refusing changed audio identity')
            return old
        subprocess.run(['cp', '-cR', str(dest), str(stage)], check=True)
        for name, entry in files.items():
            path = safe_path(stage, name); path.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256(); count = 0
            with urlopen(entry['url'], timeout=60) as response, path.open('xb') as output:
                if urlparse(response.geturl()).scheme != 'https': raise ValueError('audio redirect must stay HTTPS')
                for block in iter(lambda: response.read(1 << 20), b''):
                    count += len(block)
                    if count > entry['bytes']: raise ValueError('audio download exceeds pinned size: ' + name)
                    digest.update(block); output.write(block)
                output.flush(); os.fsync(output.fileno())
            if count != entry['bytes'] or digest.hexdigest() != entry['sha256']:
                raise ValueError('audio download size/SHA-256 mismatch: ' + name)
        manifest = dict(old, audio_identity=audio['identity'], files={**old['files'], **pins},
                        production_assets=old['production_assets'] + [dict(path='audio.aimodel', sha256=audio['identity']['asset_sha256'])])
        write_manifest(stage, manifest, installer)
        publish(stage, dest)
    return manifest


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Describe an authored text.aimodel package for the release manifest')
    parser.add_argument('asset', type=Path)
    args = parser.parse_args()
    def sha(path):
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1 << 20), b''): digest.update(block)
        return digest.hexdigest()
    files = inventory(args.asset, sha)
    print(json.dumps(dict(path='text.aimodel', bytes=sum(e['bytes'] for e in files.values()),
                          sha256=inventory_hash(files), files=files), indent=2, sort_keys=True))
