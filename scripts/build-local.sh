#!/usr/bin/env bash
#
# Local, personal-use build of lhg-CueRecord: ad-hoc signed, no Apple Developer
# account, no notarization. Not for distribution.
#
#   scripts/build-local.sh              # build only
#   scripts/build-local.sh --install    # build, then copy to ~/Applications
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/build/DerivedData"
PRODUCT="$DD/Build/Products/Release/CueRecord.app"
INSTALL_DIR="$HOME/Applications"
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Prefer a full Xcode install without needing "sudo xcode-select". Newest wins;
# xcodes installs to /Applications/Xcode-<version>.app, App Store to Xcode.app.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for candidate in $(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V); do
    if [ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
    fi
  done
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  cat >&2 <<'MSG'
error: xcodebuild not found.

Install Xcode (16.4 is the newest release that runs on macOS 15.3), then:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  xcodebuild -version
MSG
  exit 1
fi

echo "ℹ️  Xcode: $(xcodebuild -version | head -1)"

echo "🔎 Checking Git LFS assets…"
missing=0
for asset in \
  "Vendor/Models/sherpa-onnx-streaming-paraformer-bilingual-zh-en/encoder.int8.onnx" \
  "Vendor/Models/sherpa-onnx-streaming-paraformer-bilingual-zh-en/decoder.int8.onnx" \
  "Vendor/SherpaOnnxShared/lib/libsherpa-onnx-c-api.dylib" \
  "Vendor/SherpaOnnxShared/lib/libonnxruntime.1.24.4.dylib" \
  "Vendor/SherpaOnnx/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a"
do
  path="$ROOT/$asset"
  if [ ! -f "$path" ]; then
    echo "  missing: $asset"
    missing=1
  elif [ "$(stat -f%z "$path")" -lt 100000 ]; then
    echo "  still a Git LFS pointer: $asset"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "error: run 'git lfs install && git lfs pull' first." >&2
  exit 1
fi

echo "🧹 Preparing build directory…"
rm -rf "$DD"
mkdir -p "$DD"

echo "🔨 Building Release (ad-hoc signed)…"
xcodebuild \
  -project "$ROOT/CueRecord.xcodeproj" \
  -scheme CueRecord \
  -configuration Release \
  -derivedDataPath "$DD" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  build

if [ ! -d "$PRODUCT" ]; then
  echo "error: build finished but $PRODUCT is missing" >&2
  exit 1
fi

echo "✅ Built: $PRODUCT"
codesign -dv "$PRODUCT" 2>&1 | sed -n '1,3p'

if [ "$INSTALL" -eq 1 ]; then
  mkdir -p "$INSTALL_DIR"
  echo "📦 Installing to $INSTALL_DIR/CueRecord.app"
  rm -rf "$INSTALL_DIR/CueRecord.app"
  ditto "$PRODUCT" "$INSTALL_DIR/CueRecord.app"
  echo "✅ Installed. Bundle ID: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_DIR/CueRecord.app/Contents/Info.plist")"
  cat <<'MSG'

Next:
  open ~/Applications/CueRecord.app
  - This build uses com.lhg.cuerecord, so it is a separate app from the
    /Applications/CueRecord.app you installed from upstream. Both can coexist.
  - First launch: pick your vault folder again, then re-grant Screen Recording,
    Microphone, Camera and System Audio.
  - After every rebuild the ad-hoc signature changes and macOS treats it as a new
    app, so expect to re-grant Screen Recording each time.
MSG
fi
