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
PRODUCT=""   # resolved after the build from Build/Products/Release/*.app
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
  CODE_SIGN_ENTITLEMENTS=CueRecord/CueRecord.entitlements \
  ENABLE_HARDENED_RUNTIME=YES \
  build

PRODUCT="$(ls -d "$DD"/Build/Products/Release/*.app 2>/dev/null | head -1)"
if [ -z "$PRODUCT" ] || [ ! -d "$PRODUCT" ]; then
  echo "error: build finished but no .app found in $DD/Build/Products/Release" >&2
  exit 1
fi
APP_BASENAME="$(basename "$PRODUCT")"

# ad-hoc 签名的默认「代码要求」是它自己的 cdhash，每次重新构建都会变。
# 对 TCC 来说那就是另一个应用，用户已经勾过的屏幕录制/摄像头/麦克风全部作废、
# 每次启动都重新弹窗。这里重签一次，把代码要求固定成 bundle id，
# 这样跨构建稳定，权限只授权一次就够。
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PRODUCT/Contents/Info.plist")"
echo "🖋  Re-signing with a stable designated requirement ($BUNDLE_ID)…"
codesign --force --sign - \
  --identifier "$BUNDLE_ID" \
  -r="designated => identifier \"$BUNDLE_ID\"" \
  --entitlements "$ROOT/CueRecord/CueRecord.entitlements" \
  --options runtime \
  "$PRODUCT"
codesign --verify --strict "$PRODUCT"

echo "✅ Built: $PRODUCT"
codesign -dv "$PRODUCT" 2>&1 | sed -n '1,3p'
codesign -d -r- "$PRODUCT" 2>&1 | tail -1

if [ "$INSTALL" -eq 1 ]; then
  mkdir -p "$INSTALL_DIR"
  TARGET="$INSTALL_DIR/$APP_BASENAME"
  echo "📦 Installing to $TARGET"
  rm -rf "$TARGET"
  ditto "$PRODUCT" "$TARGET"
  echo "✅ Installed. Bundle ID: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist")"
  echo "   Display name:  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$TARGET/Contents/Info.plist")"
  cat <<'MSG'

Next:
  open ~/Applications/LLSStudio.app
  - This build uses its own bundle id, so it is a separate app from the
    /Applications/CueRecord.app you installed from upstream. Both can coexist.
  - First launch: pick your vault folder again, then re-grant Screen Recording,
    Microphone, Camera and System Audio.
  - After every rebuild the ad-hoc signature changes and macOS treats it as a new
    app, so expect to re-grant Screen Recording each time.
MSG
fi
