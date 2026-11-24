#!/bin/bash
# Build FFmpeg 9.1 into vendor/ so the app can embed it.
# Homebrew’s formula is still 9.0.2. This does not replace /opt/homebrew/bin/ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="9.1"
PREFIX="$(pwd)/vendor"
URL="https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz"
ASC_URL="${URL}.asc"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if [[ "${1:-}" != "--force" ]] && [[ -x "${PREFIX}/bin/ffmpeg" ]]; then
  current="$("${PREFIX}/bin/ffmpeg" -version | awk 'NR==1 { print $3 }')"
  if [[ "${current}" == "${VERSION}" ]]; then
    echo "vendor/bin/ffmpeg is already ${VERSION}"
    exit 0
  fi
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

echo "==> Downloading FFmpeg ${VERSION}…"
curl -fsSL -o "${WORK}/ffmpeg.tar.xz" "${URL}"
curl -fsSL -o "${WORK}/ffmpeg.tar.xz.asc" "${ASC_URL}"

if ! command -v gpg >/dev/null 2>&1; then
  echo "error: gpg is required to check the FFmpeg release signature. Install with: brew install gnupg" >&2
  exit 1
fi

echo "==> Checking the release signature…"
curl -fsSL -o "${WORK}/ffmpeg-devel.asc" "https://ffmpeg.org/ffmpeg-devel.asc"
gpg --batch --import "${WORK}/ffmpeg-devel.asc"
gpg --batch --verify "${WORK}/ffmpeg.tar.xz.asc" "${WORK}/ffmpeg.tar.xz"

echo "==> Unpacking…"
tar -xJf "${WORK}/ffmpeg.tar.xz" -C "${WORK}"
SRC="${WORK}/ffmpeg-${VERSION}"
if [[ ! -d "${SRC}" ]]; then
  echo "error: expected ${SRC} after unpacking" >&2
  exit 1
fi
cd "${SRC}"

export PKG_CONFIG_PATH="/opt/homebrew/opt/openssl@4/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"

echo "==> Configuring…"
./configure \
  --prefix="${PREFIX}" \
  --enable-shared \
  --enable-pthreads \
  --enable-version3 \
  --enable-gpl \
  --enable-libsvtav1 \
  --enable-libopus \
  --enable-libx264 \
  --enable-libmp3lame \
  --enable-libdav1d \
  --enable-libvmaf \
  --enable-libvpx \
  --enable-libx265 \
  --enable-openssl \
  --enable-videotoolbox \
  --enable-audiotoolbox \
  --enable-neon \
  --disable-ffplay \
  --disable-debug \
  --extra-cflags="-I/opt/homebrew/include" \
  --extra-ldflags="-L/opt/homebrew/lib"

echo "==> Compiling…"
make -j"$(sysctl -n hw.ncpu)"
make install

echo "Built $("${PREFIX}/bin/ffmpeg" -version | head -1)"
