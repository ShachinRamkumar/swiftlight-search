#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-all}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
ARCH="$(uname -m)"
SDK_VER="$(xcrun --show-sdk-version)"
TARGET="${SWIFTLIGHT_TARGET:-${ARCH}-apple-macos${SDK_VER}}"

mkdir -p build.noindex

build_frontend() {
  clang -O2 -fobjc-arc -c frontend/NativeUIAdapter.m -o build.noindex/NativeUIAdapter.o
  clang -O2 -fobjc-arc -c frontend/NativePresentation.m -o build.noindex/NativePresentation.o
  swiftc -O -parse-as-library -target "$TARGET" -import-objc-header frontend/NativeMaterial.h \
    frontend/Launcher.swift \
    frontend/PanelOpenPreparation.swift \
    frontend/FolderAccess.swift \
    frontend/FolderAccessView.swift \
    frontend/SupportDirectory.swift \
    frontend/OpeningKeyBuffer.swift \
    frontend/Results.swift \
    frontend/AppOpening.swift \
    frontend/PendingOpen.swift \
    frontend/LoginItem.swift \
    frontend/NativeMaterial.swift \
    build.noindex/NativeUIAdapter.o \
    build.noindex/NativePresentation.o \
    -framework Carbon \
    -framework ServiceManagement \
    -framework QuartzCore \
    -framework QuickLookUI \
    -o build.noindex/Launcher
  echo "Built build.noindex/Launcher ($TARGET)"
}

build_backend() {
  local cargo_flags=(build --release --locked -j 2)
  if [[ "${CARGO_NET_OFFLINE:-false}" == "true" ]]; then
    cargo_flags+=(--offline)
  fi
  (cd backend && cargo "${cargo_flags[@]}")
}

build_indexer() {
  if [[ -d vendor/DigUp/Vendor/hf-tokenizer/crates ]]; then
    (cd vendor/DigUp && CARGO_NET_OFFLINE=true sh Vendor/hf-tokenizer/build-offline.sh)
  else
    (cd vendor/DigUp/Vendor/hf-tokenizer && CARGO_NET_OFFLINE=false cargo build --release --locked -j 2)
  fi
  python3 - <<'PLISTS'
import plistlib
from pathlib import Path
for name, identifier in [('production', 'com.shachin.swiftlight.indexer'), ('validation', 'com.shachin.swiftlight.validation')]:
    Path('build.noindex/cache-' + name + '.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier)))
PLISTS
  local build_root="$PWD"
  for product in digup coreai-check; do
    (cd vendor/DigUp && swift build --disable-sandbox -c release --product "$product" --jobs 2 --disable-automatic-resolution \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$build_root/build.noindex/cache-validation.plist")
  done
  cp -c vendor/DigUp/.build/release/digup build.noindex/digup-validation
  (cd vendor/DigUp && swift build --disable-sandbox -c release --product digup --jobs 2 --disable-automatic-resolution \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$build_root/build.noindex/cache-production.plist")
}

case "$MODE" in
  --frontend-only)
    build_frontend
    exit 0
    ;;
  --backend-only)
    build_backend
    exit 0
    ;;
  all)
    build_indexer
    build_backend
    build_frontend
    ;;
  *)
    echo "Usage: $0 [all|--frontend-only|--backend-only]" >&2
    exit 2
    ;;
esac

APP="build.noindex/Swiftlight.app"
rm -f "$APP/Contents/Resources/llama.cpp-LICENSE.txt"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp build.noindex/Launcher "$APP/Contents/MacOS/Launcher"
cp backend/target/release/spotlight-backend "$APP/Contents/Helpers/Swiftlight Search"
cp vendor/DigUp/.build/release/digup "$APP/Contents/Helpers/Swiftlight Indexer"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY.md "$APP/Contents/Resources/THIRD_PARTY.md"
cp vendor/DigUp/LICENSE "$APP/Contents/Resources/DigUp-LICENSE.txt"
cp vendor/DigUp/Vendor/libjpeg-turbo/share/doc/libjpeg-turbo/LICENSE.md "$APP/Contents/Resources/libjpeg-turbo-LICENSE.md"
cp vendor/DigUp/Vendor/libjpeg-turbo/share/doc/libjpeg-turbo/README.ijg "$APP/Contents/Resources/libjpeg-turbo-README.ijg"
cp vendor/DigUp/Sources/CZstd/LICENSE "$APP/Contents/Resources/zstd-LICENSE.txt"
cp vendor/DigUp/Vendor/hf-tokenizer/LICENSE "$APP/Contents/Resources/hf-tokenizer-LICENSE.txt"
rm -rf "$APP/Contents/Resources/hf-tokenizer-licenses" "$APP/Contents/Resources/backend-licenses"
cp -R vendor/DigUp/Vendor/hf-tokenizer/licenses "$APP/Contents/Resources/hf-tokenizer-licenses"
cp -R backend/licenses "$APP/Contents/Resources/backend-licenses"
python3 - "$APP" "$SDK_VER" <<'PY'
import plistlib, sys, json
from pathlib import Path
app = Path(sys.argv[1])
min_os = sys.argv[2]
info = dict(
    CFBundleIdentifier='com.shachin.swiftlight',
    CFBundleName='Swiftlight',
    CFBundleDisplayName='Swiftlight',
    CFBundleExecutable='Launcher',
    CFBundlePackageType='APPL',
    CFBundleShortVersionString='0.1.0',
    CFBundleVersion='1',
    LSUIElement=True,
    NSHighResolutionCapable=True,
    LSMinimumSystemVersion=min_os,
    NSDocumentsFolderUsageDescription='Search your documents by filename and meaning.',
    NSDesktopFolderUsageDescription='Search files on your Desktop.',
    NSDownloadsFolderUsageDescription='Search files in Downloads.',
)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(app / 'Contents/Resources/scope-exclusions.json').write_text(json.dumps([str(Path('verification').resolve())]))
PY
codesign --force --sign "$CODESIGN_IDENTITY" --identifier com.shachin.swiftlight.indexer "$APP/Contents/Helpers/Swiftlight Indexer"
codesign --force --sign "$CODESIGN_IDENTITY" --identifier com.shachin.swiftlight.search "$APP/Contents/Helpers/Swiftlight Search"
codesign --force --sign "$CODESIGN_IDENTITY" --identifier com.shachin.swiftlight "$APP"
rm -f build.noindex/digup-validation
echo "Built $APP"
