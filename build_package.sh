#!/usr/bin/env bash
#
# Whisper Subtitler - Windows package builder (run on Debian with mingw-w64).
#
# Produces: dist/WhisperSubtitler/ and WhisperSubtitler.zip
#
# Requirements on the build machine:
#   - curl, unzip
#   - x86_64-w64-mingw32-gcc (mingw-w64)
#   - python3 with pip
#
set -euo pipefail

PY_VER="${PY_VER:-3.11.9}"
PY_MAJOR="${PY_VER%%.*}"
PY_MINOR="${PY_VER#*.}"
PY_MINOR="${PY_MINOR%%.*}"
PY_SHORT="${PY_MAJOR}${PY_MINOR}"
PY_EMBED="python-${PY_VER}-embed-amd64.zip"
PY_URL="https://www.python.org/ftp/python/${PY_VER}/${PY_EMBED}"

FFMPEG_ZIP="ffmpeg-master-latest-win64-gpl.zip"
FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/${FFMPEG_ZIP}"

WORK="build"
STAGE="dist/WhisperSubtitler"
APP_NAME="WhisperSubtitler"
ZIP_OUT="WhisperSubtitler.zip"

echo "==> Preparing work folders"
rm -rf "$WORK" "$STAGE"
mkdir -p "$WORK/wheels" "$STAGE/ffmpeg" "$STAGE/python"

echo "==> [1/6] Downloading embedded Python ${PY_VER} for Windows"
if [ ! -f "$WORK/$PY_EMBED" ]; then
    curl -L --fail --retry 3 -o "$WORK/$PY_EMBED" "$PY_URL"
fi
unzip -q -o "$WORK/$PY_EMBED" -d "$STAGE/python"

echo "==> [2/6] Enabling site-packages in embedded Python"
cat > "$STAGE/python/python${PY_SHORT}._pth" <<EOF
python${PY_SHORT}.zip
.
Lib
Lib\\site-packages

# Enable site.main() so site-packages is loaded
import site
EOF

echo "==> [3/6] Downloading ffmpeg for Windows"
if [ ! -f "$WORK/$FFMPEG_ZIP" ]; then
    curl -L --fail --retry 3 -o "$WORK/$FFMPEG_ZIP" "$FFMPEG_URL"
fi
rm -rf "$WORK/ffmpeg_extract"
unzip -q "$WORK/$FFMPEG_ZIP" -d "$WORK/ffmpeg_extract"
FFMPEG_BIN_DIR=$(find "$WORK/ffmpeg_extract" -type d -name bin -path "*win64-gpl*" | head -n 1)
if [ -z "$FFMPEG_BIN_DIR" ]; then
    echo "ERROR: could not locate ffmpeg.exe inside the downloaded archive." >&2
    exit 1
fi
cp "$FFMPEG_BIN_DIR/ffmpeg.exe" "$STAGE/ffmpeg/ffmpeg.exe"
echo "    ffmpeg.exe -> $STAGE/ffmpeg/ffmpeg.exe"

echo "==> [4/6] Downloading faster-whisper + dependencies as Windows wheels"
python3 -m pip download \
    --dest "$WORK/wheels" \
    --platform win_amd64 \
    --python-version "$PY_VER" \
    --implementation cp \
    --only-binary=:all: \
    faster-whisper

echo "==> [4b/6] Downloading translation engine (Argos Translate) as Windows wheels"
python3 -m pip download \
    --dest "$WORK/wheels" \
    --platform win_amd64 \
    --python-version "$PY_VER" \
    --implementation cp \
    --only-binary=:all: \
    --no-deps \
    argostranslate minisbd sacremoses sentencepiece regex joblib

echo "==> [5/6] Installing wheels into embedded Python"
SITE_PACKAGES="$STAGE/python/Lib/site-packages"
mkdir -p "$SITE_PACKAGES"
for whl in "$WORK"/wheels/*.whl; do
    [ -e "$whl" ] || continue
    echo "    extracting $(basename "$whl")"
    unzip -q -o "$whl" -d "$SITE_PACKAGES"
done

echo "==> [5b/6] Patching argostranslate (lazy stanza import, MiniSBD default)"
python3 - "$SITE_PACKAGES/argostranslate/sbd.py" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old = "import stanza"
new = "stanza = None\ntry:\n    import stanza\nexcept Exception:\n    stanza = None"
if old in src and "try:\n    import stanza" not in src:
    src = src.replace(old, new, 1)
    open(p, "w", encoding="utf-8").write(src)
    print("    sbd.py patched (stanza -> lazy)")
else:
    print("    sbd.py: patched or stanza not found, skipping")
PYEOF
python3 - "$SITE_PACKAGES/argostranslate/translate.py" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
# Prefer MiniSBD over Stanza: stanza is not bundled (it would need torch ~2GB).
old = """            if "stanza" in str(pkg.packaged_sbd_path):
                Sentencizer = StanzaSentencizer
            elif "minisbd" in str(pkg.packaged_sbd_path):
                Sentencizer = MiniSBDSentencizer"""
new = """            if "minisbd" in str(pkg.packaged_sbd_path):
                Sentencizer = MiniSBDSentencizer
            elif "stanza" in str(pkg.packaged_sbd_path):
                Sentencizer = MiniSBDSentencizer"""
if old in src and "Sentencizer = MiniSBDSentencizer\n            elif" not in src:
    src = src.replace(old, new, 1)
    src = src.replace(
        "        elif settings.chunk_type == settings.ChunkType.STANZA:\n            Sentencizer = StanzaSentencizer",
        "        elif settings.chunk_type == settings.ChunkType.STANZA:\n            Sentencizer = MiniSBDSentencizer",
        1,
    )
    open(p, "w", encoding="utf-8").write(src)
    print("    translate.py patched (MiniSBD default, stanza -> MiniSBD)")
else:
    print("    translate.py: patch already applied or pattern changed")
PYEOF

echo "==> [6/7] Compiling Windows launcher (with custom icon) and assembling package"
RES_OBJ="$WORK/launcher.res"
x86_64-w64-mingw32-windres launcher.rc -O coff -o "$RES_OBJ"
x86_64-w64-mingw32-gcc -O2 -mwindows -o "$STAGE/$APP_NAME.exe" launcher.c "$RES_OBJ" -lshlwapi
cp whisper_gui.pyw "$STAGE/whisper_gui.pyw"
cp assets/WhisperSubtitler.ico "$STAGE/WhisperSubtitler.ico"
echo "    WhisperSubtitler.exe (custom icon) + whisper_gui.pyw copied"

cat > "$STAGE/README.txt" <<EOF
=======================================
  Whisper Subtitler
=======================================

What this is
------------
A small program that generates .srt subtitle files from video files
using speech recognition (Whisper). Everything runs on your PC,
no video is uploaded anywhere.

Requirements
------------
- Windows 10/11 64-bit
- A working internet connection on the FIRST use only
  (needed to download the speech recognition model)

How to use
----------
1. Double-click WhisperSubtitler.exe
2. Browse for the video file (mp4, mkv, webm, avi, mov, ...)
3. Choose the subtitle (target) language. The speech in the video is
   always detected automatically; if the selected language is different,
   the subtitles are translated locally (Argos Translate, direct pair or
   pivoted through English).
4. Choose the model size:
      tiny    = fastest, less accurate
      small   = recommended balance (default)
      medium  = slower, more accurate
      large-v3 = slowest, most accurate
5. Click "Generate SRT Subtitles" and wait.
   A progress bar and a log panel show what is happening.
6. When finished, the .srt file is saved next to your video.

First run (one time only)
-------------------------
On the first run the app downloads the requested Whisper model
from HuggingFace, and -- only if you use a translation -- the required
translation packages from Argos Translate. This can take a few minutes
depending on the model and your connection. Everything is stored inside
this application folder ("models" and "translations" folders), so you
need write permissions there and everything is offline afterwards.

Notes
-----
- The whole folder is portable: you can move it or copy it to a
  USB stick, no installation is required.
- To remove the app, just delete the folder.
- Transcription runs on the CPU; a recent processor is recommended.
- License: the app is free software. ffmpeg is bundled under its
  GPL license. The Whisper models come from HuggingFace.
EOF

echo "==> [7/7] Adding tkinter (Tcl/Tk) to embedded Python"
TCLTK_MSI="$WORK/tcltk.msi"
if [ ! -f "$TCLTK_MSI" ]; then
    curl -L --fail --retry 3 -o "$TCLTK_MSI" \
        "https://www.python.org/ftp/python/${PY_VER}/amd64/tcltk.msi"
fi

# Extract tcltk.msi. Prefer msiextract (msitools): it is deterministic and
# works headless, unlike wine msiexec which needs an X server and is flaky in
# containers. Fall back to wine for machines that only have it.
TCLTK_OUT="$WORK/tcltk_extract"
rm -rf "$TCLTK_OUT"
mkdir -p "$TCLTK_OUT"
if command -v msiextract >/dev/null 2>&1; then
    echo "    extracting tcltk.msi with msiextract"
    TCLTK_MSI_ABS="$(cd "$(dirname "$TCLTK_MSI")" && pwd)/$(basename "$TCLTK_MSI")"
    ( cd "$TCLTK_OUT" && msiextract "$TCLTK_MSI_ABS" >/dev/null )
    TCLTK_ROOT="$TCLTK_OUT"
elif command -v wine >/dev/null 2>&1; then
    echo "    extracting tcltk.msi with wine"
    TCLTK_MSI_WIN_PATH="Z:$(echo "$PWD" | sed 's|/|\\|g')\\build\\tcltk.msi"
    WINEDEBUG=-all wine msiexec /a "$TCLTK_MSI_WIN_PATH" /qn "TARGETDIR=C:\\tcltk_extract" >/dev/null 2>&1
    TCLTK_ROOT="${WINEPREFIX:-$HOME/.wine}/drive_c/tcltk_extract"
else
    echo "ERROR: neither msiextract nor wine is available to extract tcltk.msi." >&2
    echo "       Install msitools (msiextract) or wine on the build machine." >&2
    exit 1
fi

[ -d "$TCLTK_ROOT" ] || { echo "ERROR: tcltk.msi extraction failed ($TCLTK_ROOT)." >&2; exit 1; }

# Locate the components wherever the extractor placed them, so the same code
# works for both the msiextract and the wine layouts. `-print -quit` stops at
# the first match without a `| head` pipe (which would trip `pipefail`).
TCLTK_PYD="$(find "$TCLTK_ROOT" -name '_tkinter.pyd' -print -quit)"
TCLTK_TCL_DLL="$(find "$TCLTK_ROOT" -name 'tcl86t.dll' -print -quit)"
TCLTK_TK_DLL="$(find "$TCLTK_ROOT" -name 'tk86t.dll' -print -quit)"
TCLTK_TKINTER_INIT="$(find "$TCLTK_ROOT" -path '*/tkinter/__init__.py' -print -quit)"
TCLTK_TKINTER_DIR=""
if [ -n "$TCLTK_TKINTER_INIT" ]; then
    TCLTK_TKINTER_DIR="$(dirname "$TCLTK_TKINTER_INIT")"
fi
TCLTK_TCL_DIR="$(find "$TCLTK_ROOT" -type d -name 'tcl8.6' -print -quit)"
TCLTK_TK_DIR="$(find "$TCLTK_ROOT" -type d -name 'tk8.6' -print -quit)"

for _component in "$TCLTK_PYD" "$TCLTK_TCL_DLL" "$TCLTK_TK_DLL" \
                  "$TCLTK_TKINTER_DIR" "$TCLTK_TCL_DIR" "$TCLTK_TK_DIR"; do
    if [ -z "$_component" ] || [ ! -e "$_component" ]; then
        echo "ERROR: missing tkinter component (last searched: '${_component:-none}')." >&2
        exit 1
    fi
done

cp "$TCLTK_PYD"     "$STAGE/python/"
cp "$TCLTK_TCL_DLL" "$STAGE/python/"
cp "$TCLTK_TK_DLL"  "$STAGE/python/"
cp -r "$TCLTK_TKINTER_DIR" "$STAGE/python/Lib/tkinter"
rm -rf "$STAGE/python/Lib/tkinter/test"
mkdir -p "$STAGE/python/tcl"
cp -r "$TCLTK_TCL_DIR" "$STAGE/python/tcl/tcl8.6"
cp -r "$TCLTK_TK_DIR"  "$STAGE/python/tcl/tk8.6"
rm -rf "$STAGE/python/tcl/tk8.6/demos" "$STAGE/python/tcl/tk8.6/images/demos" 2>/dev/null || true
rm -rf "$TCLTK_OUT"
echo "    tkinter + Tcl/Tk runtime installed"

echo "==> Zipping package"
rm -f "$ZIP_OUT"
python3 - <<'PYEOF'
import shutil, os
shutil.make_archive("dist/WhisperSubtitler", "zip", root_dir="dist", base_dir="WhisperSubtitler")
PYEOF
mkdir -p dist
mv dist/WhisperSubtitler.zip "$ZIP_OUT"

echo "==> Building self-installing setup (NSIS)"
LOCAL_NSIS="$(pwd)/.local/nsis"
if ! command -v makensis >/dev/null 2>&1; then
    if [ -x "$LOCAL_NSIS/usr/bin/makensis" ]; then
        export PATH="$LOCAL_NSIS/usr/bin:$PATH"
    else
        echo "    WARNING: 'makensis' not found (run tools/setup_nsis.sh first)."
        echo "    Skipping installer build."
        SKIP_INSTALLER=1
    fi
fi
if [ -z "${SKIP_INSTALLER:-}" ]; then
    if command -v makensis >/dev/null 2>&1; then
        export NSISDIR="${NSISDIR:-/usr/share/nsis}"
        if [ -d "$NSISDIR/Stubs" ]; then
            makensis -V3 installer.nsi
        elif [ -d "$LOCAL_NSIS/usr/share/nsis/Stubs" ]; then
            NSISDIR="$LOCAL_NSIS/usr/share/nsis" makensis -V3 installer.nsi
        else
            echo "    WARNING: NSIS data files not found. Skipping installer."
            echo "    (env: NSISDIR=/path/to/nsis-shared-files)"
        fi
    else
        echo "    WARNING: 'makensis' not found. Skipping installer build."
    fi
fi

echo
echo "Done!"
echo "  Folder       : $STAGE/"
echo "  Zip          : $ZIP_OUT"
echo "  Setup exe    : WhisperSubtitler_Setup.exe (if NSIS was available)"
du -sh "$STAGE" "$ZIP_OUT" 2>/dev/null || true