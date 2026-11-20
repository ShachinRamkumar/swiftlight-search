#!/usr/bin/env python3
"""Read model storage without changing installed assets or caches."""
import argparse
import datetime
import json
from pathlib import Path


def measure(path):
    entries = [path] if path.is_file() else sorted(path.rglob('*'))
    files = [entry for entry in entries if entry.is_file() and not entry.is_symlink()]
    return {
        'path': str(path),
        'exists': path.exists(),
        'files': len(files),
        'logical_bytes': sum(entry.stat().st_size for entry in files),
        'reported_allocated_bytes': sum(entry.stat().st_blocks * 512 for entry in files),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    support = Path.home() / 'Library/Application Support'
    parser.add_argument('--runtime', type=Path, default=support / 'Swiftlight/CoreAI/coreai-eg2-v1')
    parser.add_argument('--cache', type=Path, default=support / 'coreai-cache')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = args.runtime.expanduser()
    manifest = json.loads((root / 'manifest.json').read_text())
    functions = {'q32':'text-query', 'q64':'text-query', 'q128':'text-query',
                 'd256':'text-doc', 'd512':'text-doc', 'd1024':'text-doc', 'd2048':'text-doc',
                 'v630':'vision', 'v1260':'vision', 'v2520':'vision', 'a3000':'audio'}
    declared = {a['path'] for a in manifest['production_assets']}
    routed = {name: manifest.get('function_assets', {}).get(name,
        ('EmbeddingGemma2.aimodel' if 'EmbeddingGemma2.aimodel' in declared and tower != 'audio' else ('text' if 'text.aimodel' in declared and tower.startswith('text-') else tower) + '.aimodel'))
        for name, tower in functions.items()}
    routed = {name: asset for name, asset in routed.items() if asset in declared or asset.startswith('function-assets/')}
    assets = []
    for asset in sorted(root.rglob('*.aimodel')):
        relative = str(asset.relative_to(root))
        entry = measure(asset)
        entry['relative_path'] = relative
        entry['functions'] = sorted(key for key, value in routed.items() if value == relative)
        entry['routed_by_current_loader'] = relative in routed.values()
        assets.append(entry)
    baseline = 309_855_456 + 554_821_024
    runtime = measure(root)
    unused_originals = sum(entry['logical_bytes'] for entry in assets if not entry['routed_by_current_loader'])
    partitions = sum(entry['logical_bytes'] for entry in assets if entry['relative_path'].startswith('function-assets/'))
    report = {
        'measured_at': datetime.datetime.now().astimezone().isoformat(),
        'digup_pinned_model_bytes': baseline,
        'runtime': runtime,
        'cache': measure(args.cache.expanduser()),
        'assets': assets,
        'supporting_files': [measure(path) for path in sorted(root.iterdir()) if path.name not in {'function-assets'} and not path.name.endswith('.aimodel')],
        'scenarios': {
            'drop_unrouted_originals_source_bytes': runtime['logical_bytes'] - unused_originals,
            'return_to_original_assets_source_bytes': runtime['logical_bytes'] - partitions,
        },
        'caveats': [
            'Allocated block counts do not identify shared APFS extents or exact reclaimable space.',
            'Scenarios are byte arithmetic, not validated runnable deployments.',
            'Deleting unrouted originals currently fails runtime validation.',
            'Returning to original assets removes recovery isolation and needs measurement.',
            'Core AI cache totals exclude separate OS-managed ANE caches.',
            'Single-model recovery also uses sibling .coreai-setup and .coreai-recovery folders; count hard-linked inodes once across runtime and cache.',
            'Future audio compilation can increase cache size; audio sources are included.',
        ],
    }
    content = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(content)
    print(content, end='')


if __name__ == '__main__':
    main()
