#!/bin/bash
# Verify locally prepared Core AI runtime assets against models/CoreAI/manifest.json
# and copy them into Swiftlight's Application Support folder.
# Refuses to overwrite an existing runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE=models/CoreAI
TARGET="$HOME/Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1"
[[ -e "$TARGET" ]] && { echo "$TARGET already exists; quit Swiftlight and move it aside first" >&2; exit 1; }
python3 - "$SOURCE" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
files = json.loads((root / 'manifest.json').read_text())['files']
for name, expected in sorted(files.items()):
    path = root / name
    if not path.exists():
        sys.exit(f'{name}: missing (prepare Core AI assets in models/CoreAI/ first; see models/CoreAI/README.md)')
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    if digest.hexdigest() != expected:
        sys.exit(f'{name}: checksum mismatch')
print(f'Verified {len(files)} runtime files')
PY
mkdir -p "$(dirname "$TARGET")"
cp -R "$SOURCE" "$TARGET"
echo "Installed $TARGET"
