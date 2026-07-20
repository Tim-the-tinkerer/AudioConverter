#!/bin/bash
# Build Audio Converter and embed FFmpeg into the .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

LAUNCH=true
SKIP_FFMPEG=false
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=false ;;
    --skip-ffmpeg) SKIP_FFMPEG=true ;;
  esac
done

APP="AudioConverter.app"
BIN_NAME="AudioConverter"

echo "==> Building Audio Converter (release)…"
swift build -c release

echo "==> Assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
mkdir -p "${APP}/Contents/Frameworks"

cp ".build/release/${BIN_NAME}" "${APP}/Contents/MacOS/${BIN_NAME}"
chmod +x "${APP}/Contents/MacOS/${BIN_NAME}"
cp AppInfo.plist "${APP}/Contents/Info.plist"

# Copy SPM resource bundle if present
if [[ -d ".build/release/AudioConverter_AudioConverter.bundle" ]]; then
  cp -R ".build/release/AudioConverter_AudioConverter.bundle" \
    "${APP}/Contents/Resources/"
fi

# Also place Help.html at Resources root for easy Bundle.main lookup
if [[ -f "Sources/AudioConverter/Resources/Help.html" ]]; then
  cp "Sources/AudioConverter/Resources/Help.html" "${APP}/Contents/Resources/Help.html"
fi

if [[ -f "Assets/AppIcon.icns" ]]; then
  echo "==> Installing app icon…"
  cp "Assets/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
elif [[ -d "AppIcon.iconset" ]]; then
  echo "==> Building app icon from iconset…"
  iconutil -c icns "AppIcon.iconset" -o "${APP}/Contents/Resources/AppIcon.icns"
elif [[ -f "AppIcon.icns" ]]; then
  cp "AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi

if [[ "${SKIP_FFMPEG}" == "false" ]]; then
  echo "==> Embedding FFmpeg…"
  chmod +x scripts/embed-ffmpeg.sh
  ./scripts/embed-ffmpeg.sh "${APP}"
else
  echo "==> Skipping FFmpeg embed (--skip-ffmpeg)"
fi

# Ad-hoc sign the whole app so dyld loads nested binaries cleanly
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing ${APP}…"
  codesign --force --deep -s - "${APP}" 2>/dev/null || true
fi

touch "${APP}"

echo ""
echo "Done: ${APP}"
echo "  Binary:  ${APP}/Contents/MacOS/${BIN_NAME}"
if [[ -x "${APP}/Contents/MacOS/ffmpeg" ]]; then
  echo "  FFmpeg:  embedded"
  "${APP}/Contents/MacOS/ffmpeg" -version 2>/dev/null | head -1 || true
fi

if [[ "${LAUNCH}" == "true" ]]; then
  echo "Launching…"
  open "${APP}"
fi
