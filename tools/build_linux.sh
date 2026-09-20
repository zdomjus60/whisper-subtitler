#!/usr/bin/env bash
#
# Whisper Subtitler - Linux AppImage builder (run on Debian/Ubuntu x86_64).
#
# Produces: WhisperSubtitler_Linux.AppImage  (self-contained, double-click to run)
#
# Requirements on the build machine:
#   - Debian/Ubuntu x86_64 with glibc >= 2.41-ish (the build targets the host;
#     see README for the portability caveat)
#   - curl, unzip
#   - python3 with venv + tkinter (python3-tk / python3-tkinter package)
#   - mksquashfs (squashfs-tools) and internet
#
# The AppImage bundles Python, faster-whisper, Argos Translate and a static
# ffmpeg, so it runs on any glibc Linux desktop without installing anything.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT_DIR/build_linux"
VENV="$WORK/.venv-linux"
STAGE="$WORK/AppDir"
APP_NAME="WhisperSubtitler"
APPIMAGE_NAME="WhisperSubtitler_Linux"
FFMPEG_ZIP="ffmpeg-release-amd64-static.tar.xz"
FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/${FFMPEG_ZIP}"
APPIMAGE_TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "Run this script on a Linux (Debian/Ubuntu) machine."
command -v mksquashfs >/dev/null || die "mksquashfs required (apt install squashfs-tools)"
python3 -c 'import tkinter' 2>/dev/null || die "system python3 needs tkinter (apt install python3-tk)"

mkdir -p "$WORK"
log "Creating virtual environment"
HOST_PYTHON="$(command -v python3)"
rm -rf "$VENV"
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip setuptools wheel

log "Installing faster-whisper (+ its binary deps) and pyinstaller"
python -m pip install faster-whisper pyinstaller

log "Installing Argos Translate WITHOUT stanza/spacy (avoids torch ~2GB)"
python -m pip install --no-deps argostranslate
python -m pip install minisbd "sacremoses<0.2" "sentencepiece<0.3,>=0.2.0" regex joblib cloudpickle packaging

log "Patching argostranslate (lazy stanza import, MiniSBD always)"
SITE_PACKAGES="$VENV/lib/python$(python -c 'import sys; print("%d.%d" % sys.version_info[:2])')/site-packages"
python3 - "$SITE_PACKAGES/argostranslate/sbd.py" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old = "import stanza\n"
new = "stanza = None\ntry:\n    import stanza\nexcept Exception:\n    stanza = None\n"
if old in src and "try:\n    import stanza" not in src:
    src = src.replace(old, new, 1)
    open(p, "w", encoding="utf-8").write(src)
    print("    sbd.py patched (stanza -> lazy)")
else:
    print("    sbd.py: already patched or pattern changed")
PYEOF
python3 - "$SITE_PACKAGES/argostranslate/translate.py" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
# Never use Stanza (it would need torch). MiniSBD is bundled and fast.
grade = False
old = """            if "stanza" in str(pkg.packaged_sbd_path):
                Sentencizer = StanzaSentencizer
            elif \"minisbd\" in str(pkg.packaged_sbd_path):"""
new = """            if \"minisbd\" in str(pkg.packaged_sbd_path):"""
if old in src:
    src = src.replace(old, new, 1)
    grade = True
old2 = """        elif settings.chunk_type == settings.ChunkType.STANZA:
            Sentencizer = StanzaSentencizer"""
new2 = """        elif settings.chunk_type == settings.ChunkType.STANZA:
            Sentencizer = MiniSBDSentencizer"""
if old2 in src:
    src = src.replace(old2, new2, 1)
    grade = True
if grade:
    open(p, "w", encoding="utf-8").write(src)
    print("    translate.py patched (Stanza -> MiniSBD)")
else:
    print("    translate.py: already patched or pattern changed")
PYEOF

log "Bundling a static ffmpeg binary for Linux"
FFMPEG_DIR="$WORK/ffmpeg"
rm -rf "$FFMPEG_DIR"
mkdir -p "$FFMPEG_DIR"
if [ ! -f "$WORK/$FFMPEG_ZIP" ]; then
    curl -L --fail --retry 3 -o "$WORK/$FFMPEG_ZIP" "$FFMPEG_URL"
fi
rm -rf "$WORK/ffmpeg_extract"
mkdir -p "$WORK/ffmpeg_extract"
tar -xaf "$WORK/$FFMPEG_ZIP" -C "$WORK/ffmpeg_extract"
FFMPEG_BIN=$(find "$WORK/ffmpeg_extract" -type f -name ffmpeg | head -n 1)
[ -n "$FFMPEG_BIN" ] || die "could not locate the ffmpeg binary inside the downloaded archive"
cp "$FFMPEG_BIN" "$FFMPEG_DIR/ffmpeg"
chmod +x "$FFMPEG_DIR/ffmpeg"
"$FFMPEG_DIR/ffmpeg" -version >/dev/null 2>&1 || die "bundled ffmpeg does not run on this host"

log "Generating a PNG icon for the AppImage"
"$HOST_PYTHON" - "$ROOT_DIR/assets/WhisperSubtitler.ico" "$WORK/whisper-subtitler.png" <<'PYEOF'
import sys
from PIL import Image
img = Image.open(sys.argv[1])
frames = [f for f in (img.convert("RGBA"),)]
f = frames[0]
for target in (256, 128, 64, 48, 32):
    if f.size[0] >= target:
        f = f.resize((target, target), Image.Resampling.LANCZOS)
        break
f.save(sys.argv[2], "PNG")
print("    " + sys.argv[2] + " written")
PYEOF

log "Building the one-folder PyInstaller bundle"
cd "$ROOT_DIR"
rm -rf "$WORK/build" "$WORK/spec"
cp whisper_gui.pyw "$WORK/whisper_gui.py"
python -m PyInstaller \
    --noconfirm --clean \
    --name "$APP_NAME" \
    --distpath "$WORK/dist" \
    --workpath "$WORK/build" \
    --specpath "$WORK/spec" \
    --windowed \
    --add-binary "$FFMPEG_DIR/ffmpeg:ffmpeg" \
    --collect-all faster_whisper \
    --collect-all argostranslate \
    --collect-all minisbd \
    --hidden-import joblib \
    --hidden-import cloudpickle \
    --icon "$WORK/whisper-subtitler.png" \
    "$WORK/whisper_gui.py"
DIST="$WORK/dist/$APP_NAME"
[ -d "$DIST" ] || die "PyInstaller did not produce $DIST"

log "Assembling the AppDir for appimagetool"
rm -rf "$STAGE"
mkdir -p "$STAGE/usr/bin"
cp -R "$DIST" "$STAGE/usr/bin/$APP_NAME"
cat > "$STAGE/AppRun" <<EOF
#!/bin/sh
SELF="\$(readlink -f "\$0")"
HERE="\${SELF%/*}"
export PATH="\$HERE/usr/bin/$APP_NAME:\$PATH"
exec "\$HERE/usr/bin/$APP_NAME/$APP_NAME" "\$@"
EOF
chmod +x "$STAGE/AppRun"
cp "$WORK/whisper-subtitler.png" "$STAGE/whisper-subtitler.png"
cat > "$STAGE/whisper-subtitler.desktop" <<EOF
[Desktop Entry]
Name=Whisper Subtitler
Comment=Generate .srt subtitles from videos using Whisper
Exec=$APP_NAME
Icon=whisper-subtitler
Terminal=false
Type=Application
Categories=AudioVideo;AudioVideoEditing;Utility;
X-AppImage-Version=1.0
EOF

log "Running appimagetool"
APPIMAGE_TOOL="$WORK/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGE_TOOL" ]; then
    curl -L --fail --retry 3 -o "$APPIMAGE_TOOL" "$APPIMAGE_TOOL_URL"
    chmod +x "$APPIMAGE_TOOL"
fi
( cd "$ROOT_DIR" && "$APPIMAGE_TOOL" --appimage-extract-and-run "$STAGE" >/dev/null )
OUTPUT=$(find "$ROOT_DIR" -maxdepth 1 -name "*.AppImage" 2>/dev/null | head -n 1 || true)
[ -n "$OUTPUT" ] || OUTPUT="$ROOT_DIR/WhisperSubtitler-x86_64.AppImage"
[ -f "$OUTPUT" ] || die "appimagetool did not produce an AppImage"
mv -f "$OUTPUT" "$ROOT_DIR/${APPIMAGE_NAME}.AppImage"

log "Cleaning temporary build artifacts"
rm -rf "$STAGE" "$WORK/build" "$WORK/spec" "$WORK/dist" "$WORK/whisper_gui.py" "$WORK/ffmpeg_extract"

echo
echo "FATTO."
echo "   - AppImage : $ROOT_DIR/${APPIMAGE_NAME}.AppImage"
du -sh "$ROOT_DIR/${APPIMAGE_NAME}.AppImage"
echo
echo "Per avviare:  chmod +x ${APPIMAGE_NAME}.AppImage && ./${APPIMAGE_NAME}.AppImage"