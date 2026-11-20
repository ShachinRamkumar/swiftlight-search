"""Small malformed-input and atomic optional-download tests; no model or Core AI calls."""
import hashlib
import importlib.util
import io
import json
import shutil
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_tables as codec
import storage_option_a as storage
spec = importlib.util.spec_from_file_location('installer', Path(__file__).resolve().parents[1] / 'install-coreai-runtime.py')
installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)


class CodecTests(unittest.TestCase):
    def test_planes_preserve_every_bf16_bit_pattern_and_partial_chunk(self):
        raw = struct.pack('<65536H', *range(65536)) + b'\xff\xff' * 512
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'rows.slht'
            with path.open('wb') as out: codec.pack_rows(raw, 129, 512, out)
            table = codec.PackedRows(path)
            self.assertEqual(table.decode(), raw)
            self.assertEqual(table.row(128), raw[-1024:])
            with self.assertRaises(codec.FormatError): table.row(129)
            changed = bytearray(path.read_bytes()); changed[64:72] = struct.pack('<Q', 0); path.write_bytes(changed)
            with self.assertRaises(codec.FormatError): codec.PackedRows(path)

    def test_zstd_rejects_trailing_frames_truncation_and_bad_checksum(self):
        frame = codec.frame(b'payload')
        for data in [b'bad', frame + frame, frame[:-1], frame[:-1] + bytes([frame[-1] ^ 1])]:
            with self.assertRaises(codec.FormatError): codec.unframe(data, 7)
        with self.assertRaises(codec.FormatError): codec.unframe(frame, 8)


class SemanticIdentityTests(unittest.TestCase):
    def test_changed_source_semantics_are_rejected_before_copy_or_verification(self):
        original = json.loads((Path(__file__).resolve().parents[2] / 'models/CoreAI/manifest.json').read_text())
        for changed in ('vision', 'host', 'host-file', 'text'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); source = root / 'source'; source.mkdir()
                merged = root / 'text.aimodel'; merged.mkdir(); (merged / 'main.mlirb').write_bytes(b'new source')
                entries = storage.inventory(merged, installer.sha)
                release = dict(format='swiftlight-option-a-1', semantic_revision=storage.SEMANTIC_REVISION,
                    text=dict(path='text.aimodel', bytes=10, sha256=storage.inventory_hash(entries), files=entries))
                release_file = root / 'release.json'; release_file.write_text(json.dumps(release))
                old = json.loads(json.dumps(original))
                if changed in ('vision', 'text'):
                    path = 'vision.aimodel' if changed == 'vision' else 'text-doc.aimodel'
                    next(a for a in old['production_assets'] if a['path'] == path)['sha256'] = 'a' * 64
                elif changed == 'host': old['vision_identity']['host']['host_sha256'] = 'b' * 64
                else: old['vision_identity']['host']['files']['cos.f32'] = 'c' * 64
                (source / 'manifest.json').write_text(json.dumps(old))
                with patch.object(installer, 'verify', side_effect=AssertionError('must reject before file access')):
                    with self.assertRaisesRegex(ValueError, 'source semantic'):
                        storage.install(root / 'dest/coreai-eg2-v1', source, merged, release_file, installer)

    def test_unapproved_package_cannot_claim_the_preserved_revision(self):
        original = json.loads((Path(__file__).resolve().parents[2] / 'models/CoreAI/manifest.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; source.mkdir()
            (source / 'manifest.json').write_text(json.dumps(original))
            merged = root / 'text.aimodel'; merged.mkdir(); (merged / 'main.mlirb').write_bytes(b'new source')
            entries = storage.inventory(merged, installer.sha)
            release = dict(format='swiftlight-option-a-1', semantic_revision=storage.SEMANTIC_REVISION,
                text=dict(path='text.aimodel', bytes=10, sha256=storage.inventory_hash(entries), files=entries))
            release_file = root / 'release.json'; release_file.write_text(json.dumps(release))
            with patch.object(installer, 'verify', side_effect=AssertionError('must reject before file access')):
                with self.assertRaisesRegex(ValueError, 'verified approval'):
                    storage.install(root / 'dest/coreai-eg2-v1', source, merged, release_file, installer)

    def test_python_and_swift_require_the_same_explicit_package_approval(self):
        import re
        source = (Path(__file__).resolve().parents[2] / 'vendor/DigUp/Sources/DigUpCoreAIRuntime/OptionASemanticIdentity.swift').read_text()
        value = re.search(r'let approvedMergedTextPackageSHA256: String\? = (nil|"[a-f0-9]{64}")', source).group(1)
        self.assertEqual(None if value == 'nil' else json.loads(value), storage.APPROVED_MERGED_PACKAGE_SHA256)


class VerificationStagingTests(unittest.TestCase):
    def test_unapproved_staging_is_confined_before_source_access(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(storage, 'RESEARCH_ROOT', root):
                storage.require_research_destination(root / 'staging/coreai-eg2-v1')
                for dest in (root / 'elsewhere/coreai-eg2-v1', Path.home() / 'Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1'):
                    with self.subTest(dest=dest), self.assertRaisesRegex(ValueError, 'verification staging'):
                        storage.install(dest, root / 'absent', root / 'absent-model', root / 'absent-release', installer, verification_staging=True)

    def test_generic_installer_refuses_verification_only_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; source.mkdir()
            (source / 'manifest.json').write_text(json.dumps(dict(verification_only=True)))
            with self.assertRaisesRegex(RuntimeError, 'verification-only'):
                installer.install_runtime(root / 'destination/coreai-eg2-v1', source)
            self.assertFalse((root / 'destination').exists())


class DiagnosticLayoutTests(unittest.TestCase):
    def test_diagnostics_do_not_open_removed_host_files(self):
        sources = Path(__file__).resolve().parents[2] / 'vendor/DigUp/Sources/digup'
        for name in ('C1Diagnostics.swift', 'VideoDiagnostics.swift'):
            text = (sources / name).read_text()
            for removed in ('tokenizer.json', 'token-table.bf16'):
                with self.subTest(caller=name, removed=removed):
                    self.assertNotIn('appendingPathComponent("' + removed + '")', text)


class RetainedSourceToolsTests(unittest.TestCase):
    def test_option_a_reuses_sources_without_importing_authoring_sdk_or_writing(self):
        spec = importlib.util.spec_from_file_location('prepare_function', Path(__file__).resolve().parents[1] / 'prepare-coreai-function.py')
        prepare = importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); files = {}
            for tower in ('text', 'vision'):
                path = root / (tower + '.aimodel/main.mlirb'); path.parent.mkdir(); path.write_bytes(tower.encode())
                files[str(path.relative_to(root))] = installer.sha(path)
            manifest = dict(storage_layout=storage.LAYOUT, files=files, production_assets=[dict(path=t + '.aimodel') for t in ('text', 'vision')])
            (root / 'manifest.json').write_text(json.dumps(manifest))
            before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            for function, tower in [('q32', 'text'), ('query-rest', 'text'), ('d2048', 'text'), ('v1260', 'vision'), ('vision-rest', 'vision')]:
                result = prepare.prepare(root, function)
                self.assertTrue(result['reused'])
                self.assertEqual(result['asset'], str(root / (tower + '.aimodel')))
            after = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            self.assertEqual(before, after)

    def test_storage_audit_marks_both_merged_sources_as_routed(self):
        import contextlib
        spec = importlib.util.spec_from_file_location('audit_storage', Path(__file__).resolve().parents[1] / 'audit-model-storage.py')
        audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for tower in ('text', 'vision'):
                (root / (tower + '.aimodel')).mkdir()
                (root / (tower + '.aimodel/main.mlirb')).write_bytes(b'fixture')
            (root / 'manifest.json').write_text(json.dumps(dict(production_assets=[dict(path=t + '.aimodel') for t in ('text', 'vision')])))
            output = io.StringIO()
            with patch.object(sys, 'argv', ['audit', '--runtime', str(root), '--cache', str(root / 'no-cache')]), contextlib.redirect_stdout(output): audit.main()
            assets = json.loads(output.getvalue())['assets']
            self.assertTrue(all(a['routed_by_current_loader'] for a in assets))
            self.assertEqual([len(a['functions']) for a in assets], [7, 3])


class AudioTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # These payloads are a few bytes; the real 14 GiB admission rule has its own test below.
        free_check = patch.object(storage, 'MINIMUM_FREE_BYTES', 0)
        free_check.start()
        self.addCleanup(free_check.stop)
        self.root = Path(self.tmp.name)
        self.dest = self.root / 'coreai-eg2-v1'; self.dest.mkdir()
        (self.dest / 'keep').write_bytes(b'text-and-image-stay')
        self.old = dict(storage_layout=storage.LAYOUT, semantic_revision=storage.SEMANTIC_REVISION,
                        files={'keep': installer.sha(self.dest / 'keep')}, production_assets=[])
        (self.dest / 'manifest.json').write_text(json.dumps(self.old))
        names = ['audio.aimodel/main.hash', 'audio.aimodel/main.mlirb', 'audio.aimodel/metadata.json',
                 'audio-host/window.f32', 'audio-host/mel-bank.f32', 'audio-host/mel-bank.f64', 'audio-host/positions.f32', 'audio-host/identity.json']
        self.payloads = {n: n.encode() for n in names}
        files = {n: dict(bytes=len(b), sha256=hashlib.sha256(b).hexdigest(), url='https://example.invalid/' + n) for n, b in self.payloads.items()}
        model = {n.split('/', 1)[1]: {k: e[k] for k in ('bytes', 'sha256')} for n, e in files.items() if n.startswith('audio.aimodel/')}
        identity = dict(asset_sha256=storage.inventory_hash(model), host=dict(files={n.split('/', 1)[1]: e['sha256'] for n, e in files.items() if n.startswith('audio-host/') and not n.endswith('identity.json')}))
        self.release = dict(format='swiftlight-option-a-1', audio=dict(files=files, identity=identity))
        self.release_file = self.root / 'release.json'
        self.save()

    def save(self): self.release_file.write_text(json.dumps(self.release))

    def test_space_refuses_when_free_disk_is_below_the_reserve(self):
        usage = shutil._ntuple_diskusage(total=1 << 40, used=0, free=10)
        with patch.object(storage, 'MINIMUM_FREE_BYTES', 100), patch.object(storage.shutil, 'disk_usage', return_value=usage):
            with self.assertRaises(RuntimeError):
                storage.space(self.root, 0)
            with patch.object(storage, 'MINIMUM_FREE_BYTES', 5):
                storage.space(self.root, 0)

    def response(self, url, timeout):
        result = io.BytesIO(self.payloads[url.split('example.invalid/', 1)[1]])
        result.geturl = lambda: url
        return result

    def test_verified_download_is_atomic_and_idempotent(self):
        observed = []
        def response(url, timeout):
            observed.append(json.loads((self.dest / 'manifest.json').read_text()))
            return self.response(url, timeout)
        with patch.object(storage, 'urlopen', response):
            installed = storage.download_audio(self.dest, self.release_file, installer)
        self.assertEqual(observed, [self.old] * 8)
        self.assertEqual((self.dest / 'keep').read_bytes(), b'text-and-image-stay')
        installer.verify(self.dest, installed)
        with patch.object(storage, 'urlopen', side_effect=AssertionError('must not download twice')):
            self.assertEqual(storage.download_audio(self.dest, self.release_file, installer), installed)
        self.assertEqual(list(self.root.glob('.*.stage-*')), [])

    def test_audio_enable_preserves_unapproved_staging_restriction(self):
        parent = self.root / 'staging'; parent.mkdir()
        dest = parent / 'coreai-eg2-v1'; self.dest.rename(dest); self.dest = dest
        self.old['verification_only'] = True
        self.old['candidate_semantic_revision'] = self.old.pop('semantic_revision')
        (dest / 'manifest.json').write_text(json.dumps(self.old))
        with patch.object(storage, 'RESEARCH_ROOT', self.root), patch.object(storage, 'urlopen', self.response):
            result = storage.download_audio(dest, self.release_file, installer)
        self.assertTrue(result['verification_only'])
        self.assertNotIn('semantic_revision', result)
        self.assertEqual(result['candidate_semantic_revision'], storage.SEMANTIC_REVISION)

    def test_failed_download_keeps_original_runtime_and_cleans_stage(self):
        self.payloads['audio-host/window.f32'] += b'corrupt'
        with patch.object(storage, 'urlopen', self.response):
            with self.assertRaises(ValueError): storage.download_audio(self.dest, self.release_file, installer)
        self.assertEqual(json.loads((self.dest / 'manifest.json').read_text()), self.old)
        self.assertFalse((self.dest / 'audio.aimodel').exists())
        self.assertEqual(list(self.root.glob('.*.stage-*')), [])

    def test_placeholder_urls_fail_before_writing(self):
        self.release['audio']['files']['audio.aimodel/main.hash']['url'] = 'PLACEHOLDER_AUDIO_DOWNLOAD_URL'; self.save()
        with self.assertRaises(ValueError): storage.download_audio(self.dest, self.release_file, installer)
        self.assertEqual(json.loads((self.dest / 'manifest.json').read_text()), self.old)

    def test_paths_cannot_escape_staging(self):
        for name in ['../escape', '/absolute', 'a//b', 'a/./b', 'a\0b']:
            with self.assertRaises(ValueError): storage.safe_path(self.root, name)


if __name__ == '__main__': unittest.main()
