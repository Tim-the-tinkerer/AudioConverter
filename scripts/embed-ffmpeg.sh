#!/bin/bash
# Bundle ffmpeg + ffprobe and all non-system dylibs into the .app,
# rewriting install names so the app runs without Homebrew.
# Compatible with macOS /bin/bash 3.2 (no associative arrays).
set -euo pipefail

APP_DIR="${1:?Usage: embed-ffmpeg.sh <App.app>}"
CONTENTS="${APP_DIR}/Contents"
BIN_DIR="${CONTENTS}/MacOS"
FRAMEWORKS="${CONTENTS}/Frameworks"

mkdir -p "${FRAMEWORKS}" "${BIN_DIR}"

# Prefer Homebrew binaries; fall back to PATH.
FFMPEG_SRC="${FFMPEG_PATH:-}"
FFPROBE_SRC="${FFPROBE_PATH:-}"
if [ -z "${FFMPEG_SRC}" ]; then
  for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [ -x "$candidate" ]; then FFMPEG_SRC="$candidate"; break; fi
  done
fi
if [ -z "${FFPROBE_SRC}" ]; then
  for candidate in /opt/homebrew/bin/ffprobe /usr/local/bin/ffprobe; do
    if [ -x "$candidate" ]; then FFPROBE_SRC="$candidate"; break; fi
  done
fi
if [ -z "${FFMPEG_SRC}" ]; then
  FFMPEG_SRC="$(command -v ffmpeg || true)"
fi
if [ -z "${FFPROBE_SRC}" ]; then
  FFPROBE_SRC="$(command -v ffprobe || true)"
fi

if [ -z "${FFMPEG_SRC}" ] || [ ! -x "${FFMPEG_SRC}" ]; then
  echo "error: ffmpeg not found. Install with: brew install ffmpeg" >&2
  exit 1
fi
if [ -z "${FFPROBE_SRC}" ] || [ ! -x "${FFPROBE_SRC}" ]; then
  echo "error: ffprobe not found. Install with: brew install ffmpeg" >&2
  exit 1
fi

echo "Embedding ffmpeg from: ${FFMPEG_SRC}"
echo "Embedding ffprobe from: ${FFPROBE_SRC}"

# Resolve symlinks to real binaries.
FFMPEG_SRC="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${FFMPEG_SRC}")"
FFPROBE_SRC="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${FFPROBE_SRC}")"

cp -f "${FFMPEG_SRC}" "${BIN_DIR}/ffmpeg"
cp -f "${FFPROBE_SRC}" "${BIN_DIR}/ffprobe"
chmod +x "${BIN_DIR}/ffmpeg" "${BIN_DIR}/ffprobe"

# Python helper: collect non-system dylibs recursively and copy + rewrite.
python3 - "${BIN_DIR}" "${FRAMEWORKS}" <<'PY'
import os, sys, subprocess, shutil
from pathlib import Path

bin_dir = Path(sys.argv[1])
frameworks = Path(sys.argv[2])
frameworks.mkdir(parents=True, exist_ok=True)

SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/Library/Apple/")

def is_system(path: str) -> bool:
    return path.startswith(SYSTEM_PREFIXES)

def otool_deps(binary: Path):
    try:
        out = subprocess.check_output(["otool", "-L", str(binary)], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return []
    deps = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        path = line.split()[0]
        if path.startswith("@") or is_system(path):
            continue
        if path.startswith("/"):
            deps.append(path)
    return deps

def real(p: str) -> Path:
    return Path(os.path.realpath(p))

# BFS collect
queue = []
seen = set()
for name in ("ffmpeg", "ffprobe"):
    b = bin_dir / name
    if b.exists():
        queue.append(b)

all_libs = {}  # basename -> real path

while queue:
    current = queue.pop(0)
    key = str(current)
    if key in seen:
        continue
    seen.add(key)
    for dep in otool_deps(current):
        try:
            r = real(dep)
        except OSError:
            print(f"warning: missing dependency: {dep}", file=sys.stderr)
            continue
        if not r.is_file():
            print(f"warning: missing dependency: {dep}", file=sys.stderr)
            continue
        base = os.path.basename(dep)
        realbase = r.name
        all_libs[base] = r
        all_libs[realbase] = r
        if str(r) not in seen:
            queue.append(r)

print(f"Copying {len(set(all_libs.values()))} unique dylibs into Frameworks…")
copied_real = set()
for base, rpath in all_libs.items():
    dest = frameworks / base
    if rpath.resolve() not in copied_real or not dest.exists():
        shutil.copy2(rpath, dest)
        os.chmod(dest, 0o755)
        copied_real.add(rpath.resolve())

def rewrite(binary: Path, set_id: bool):
    # Make writable
    try:
        mode = binary.stat().st_mode
        os.chmod(binary, mode | 0o200)
    except OSError:
        pass

    if set_id:
        subprocess.run(
            ["install_name_tool", "-id", f"@rpath/{binary.name}", str(binary)],
            stderr=subprocess.DEVNULL,
        )

    for dep in otool_deps(binary):
        base = os.path.basename(dep)
        if (frameworks / base).exists():
            subprocess.run(
                ["install_name_tool", "-change", dep, f"@rpath/{base}", str(binary)],
                stderr=subprocess.DEVNULL,
            )
        else:
            try:
                rb = real(dep).name
            except OSError:
                continue
            if (frameworks / rb).exists():
                subprocess.run(
                    ["install_name_tool", "-change", dep, f"@rpath/{rb}", str(binary)],
                    stderr=subprocess.DEVNULL,
                )

# Add rpath + rewrite executables
for name in ("ffmpeg", "ffprobe"):
    b = bin_dir / name
    subprocess.run(
        ["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(b)],
        stderr=subprocess.DEVNULL,
    )
    rewrite(b, set_id=False)

# Rewrite all frameworks dylibs (may need multiple passes for nested deps)
for _ in range(3):
    for dylib in frameworks.iterdir():
        if dylib.is_file():
            rewrite(dylib, set_id=True)

print("Rewrote install names.")
PY

# Codesign ad-hoc so Gatekeeper doesn't kill dylib loads
if command -v codesign >/dev/null 2>&1; then
  echo "Ad-hoc signing embedded binaries…"
  for dylib in "${FRAMEWORKS}"/*; do
    [ -f "$dylib" ] || continue
    codesign --force -s - "$dylib" 2>/dev/null || true
  done
  codesign --force -s - "${BIN_DIR}/ffmpeg" 2>/dev/null || true
  codesign --force -s - "${BIN_DIR}/ffprobe" 2>/dev/null || true
fi

# Smoke test
if "${BIN_DIR}/ffmpeg" -version >/dev/null 2>&1; then
  VER=$("${BIN_DIR}/ffmpeg" -version 2>/dev/null | head -1)
  echo "OK: bundled ffmpeg runs — ${VER}"
else
  echo "warning: bundled ffmpeg failed to run; checking errors…" >&2
  "${BIN_DIR}/ffmpeg" -version 2>&1 | head -20 || true
fi

if "${BIN_DIR}/ffprobe" -version >/dev/null 2>&1; then
  echo "OK: bundled ffprobe runs"
else
  echo "warning: bundled ffprobe failed to run" >&2
  "${BIN_DIR}/ffprobe" -version 2>&1 | head -10 || true
fi

echo "Embedded FFmpeg into ${APP_DIR}"
du -sh "${BIN_DIR}/ffmpeg" "${BIN_DIR}/ffprobe" "${FRAMEWORKS}" 2>/dev/null || true
