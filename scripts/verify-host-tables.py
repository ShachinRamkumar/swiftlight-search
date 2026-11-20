#!/usr/bin/env python3
"""Read-only source check and temporary packed round trip. Python 3.14 required."""
import argparse
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path
import host_tables as codec


def require_space(folder, extra=0):
    if shutil.disk_usage(folder).free < 12_000_000_000 + extra:
        raise RuntimeError('need at least 12 GB free after temporary output')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path.home() / 'Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1')
    parser.add_argument('--output', type=Path, help='retain packed output here for Swift checks; must not exist')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-coreai-runtime.py'))
    installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
    require_space(tempfile.gettempdir(), 200_000_000)
    manifest = json.loads((args.source / 'manifest.json').read_text())
    rope = json.loads((args.source / 'rope-tables/sha256.json').read_text())
    if codec.sha256_file(args.source / 'rope-tables/sha256.json') != installer.PINNED['rope-tables/sha256.json']:
        raise RuntimeError('RoPE pin mismatch')
    with tempfile.TemporaryDirectory(prefix='swiftlight-host-check-') as temporary:
        out = args.output or Path(temporary) / 'packed'
        out.mkdir()
        try:
            record = codec.pack(args.source, out, installer.PINNED, rope, manifest['vision_identity']['host']['files'])
            codec.verify(out, record, installer.PINNED, rope)
            # Compare retained vision rows directly, including both axes and the padding RoPE row.
            for name, entry in record['files'].items():
                if entry['kind'] == 'row-prefix':
                    original = (args.source / entry['source']).read_bytes()
                    assert (out / name).read_bytes() == codec.row_prefix(original, entry['axes'], entry['source_rows'], entry['rows'], entry['row_bytes'])
            sizes = {name: entry['bytes'] for name, entry in record['files'].items()}
            report = dict(packed_file_bytes=sizes, total_bytes=sum(sizes.values()),
                          host_manifest_bytes=(out / 'host-tables.json').stat().st_size,
                          token_sha256=installer.PINNED['token-table.bf16'], rope_tables_verified=len(rope),
                          tokenizer_exact=True, retained_vision_rows_exact=True)
            print(json.dumps(report, indent=2), flush=True)
            if args.report: args.report.write_text(json.dumps(report, indent=2) + '\n')
        except BaseException:
            if args.output: shutil.rmtree(out)
            raise


if __name__ == '__main__': main()
