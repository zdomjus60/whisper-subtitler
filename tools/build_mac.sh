#!/usr/bin/env bash
# Build the macOS Whisper Subtitler .app bundle + installer DMG.
#
# Run THIS on the Hackintosh (macOS). Produces:
#   mac/dist/Whisper Subtitler.app                    - the drag & drop app
#   mac/dist/WhisperSubtitler_Mac.dmg                 - the installer
#
# Requirements on the Mac:
#   - macOS 10.15+ (x86_64; Intel Hackintosh T480)
#   - Xcode Command Line Tools (xcode-select --install)
#   - a framework Python from python.org or Homebrew ("python3" in /usr/local)
#   - internet on the build machine (models are downloaded at first run anyway)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
VENV="$MAC_DIR/.venv-mac"
# Prefer a Python 3.11/3.12 framework build. Python 3.13/3.14 lack published
# wheels on macOS x86_64 for PyAV/ctranslate2 (faster-whisper deps).
if [ -z "${PYTHON_BIN:-}" ]; then
    for _c in /usr/local/opt/python@3.12/bin/python3.12 \
              /opt/homebrew/opt/python@3.12/bin/python3.12 \
              /usr/local/opt/python@3.11/bin/python3.11 \
              /usr/local/bin/python3.12; do
        if [ -x "$_c" ]; then PYTHON_BIN="$_c"; break; fi
    done
fi
PYTHON_BIN="${PYTHON_BIN:-/usr/local/bin/python3}"
FFMPEG_URL="${FFMPEG_URL:-https://evermeet.cx/ffmpeg/getrelease/zip}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Run this script ON the macOS machine (Hackintosh)."
command -v xcode-select >/dev/null || die "Xcode CLT required: xcode-select --install"

log "Selecting Python"
[ -x "$PYTHON_BIN" ] || PYTHON_BIN="$(command -v python3 || true)"
[ -n "${PYTHON_BIN:-}" ] || die "python3 not found. Set PYTHON_BIN=/path/to/framework/python3"
"$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.platform=="darwin" else 1)' || die "PYTHON_BIN must be a macOS Python"
if "$PYTHON_BIN" -c 'import sys; sys.exit(0 if (3,11) <= sys.version_info[:2] <= (3,12) else 1)'; then
    :
else
    die "This build needs Python 3.11 or 3.12 (macOS x86_64 wheels for PyAV/ctranslate2 are missing on other versions). Set PYTHON_BIN accordingly (e.g. PYTHON_BIN=/usr/local/opt/python@3.12/bin/python3.12)."
fi
log "Using: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

log "Creating virtual environment"
rm -rf "$VENV"
"$PYTHON_BIN" -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip setuptools wheel

log "Installing transcription + translation + packaging dependencies"
# joblib + cloudpickle are pulled in by sacremoses/joblib only at runtime
# (lazy import), so py2app drops them unless they are explicit in setup.py,
# and pip must have them in the venv for find_spec to bundle them. This is the
# fix for the translation errors seen on Windows/Linux.
python -m pip install faster-whisper argostranslate py2app joblib cloudpickle

log "Checking tkinter"
python -c 'import tkinter' \
    || die "tkinter is missing from this Python. On Homebrew Python install it with 'brew install python-tk@3.12', or use a python.org framework build."

log "Patching vendor modules to shrink the bundle"
# 1) Argos Translate hard-imports stanza (-> torch ~2 GB) at module load, but
#    this app explicitly disables stanza (ARGOS_STANZA_AVAILABLE=0) and uses the
#    ARGOSTRANSLATE few-shot chunker by default. Make the import optional so
#    torch/stanza/spacy never enter the bundle.
python - <<'PYEOF'
from pathlib import Path
import sysconfig
root = Path(sysconfig.get_paths()["purelib"])
sbd = root / "argostranslate" / "sbd.py"
src = sbd.read_text(encoding="utf-8")
old = "import stanza\n"
new = "try:\n    import stanza\nexcept ImportError:\n    stanza = None\n"
assert old in src, "argostranslate/sbd.py changed upstream"
sbd.write_text(src.replace(old, new, 1), encoding="utf-8")
print("  patched argostranslate/sbd.py (stanza import guarded)")
PYEOF

# 1b) argostranslate/translate.py must never pick the Stanza sentence splitter:
#     recent Argos packages bundle a stanza model inside the package, so
#     pkg.packaged_sbd_path points at it and StanzaSentencizer gets selected,
#     which crashes (stanza is not bundled -> AttributeError NoneType.Pipeline).
#     Force MiniSBD in every branch. Mirrors the Windows/Linux patch.
python - <<'PYEOF'
from pathlib import Path
import sysconfig
root = Path(sysconfig.get_paths()["purelib"])
p = root / "argostranslate" / "translate.py"
src = p.read_text(encoding="utf-8")
grade = False
old = """            if "stanza" in str(pkg.packaged_sbd_path):
                Sentencizer = StanzaSentencizer
            elif "minisbd" in str(pkg.packaged_sbd_path):"""
new = """            if "minisbd" in str(pkg.packaged_sbd_path):"""
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
    p.write_text(src, encoding="utf-8")
    print("  patched argostranslate/translate.py (Stanza -> MiniSBD)")
else:
    print("  argostranslate/translate.py: already patched or pattern changed")
PYEOF

# 2) faster-whisper normally decodes audio with PyAV, but PyAV macOS x86_64
#    wheels carry dylibs that py2app/macholib cannot relocate. The app already
#    ships a static ffmpeg (used by extract_audio) and sets WHISPER_FFMPEG, so
#    replace decode_audio with a plain ffmpeg subprocess implementation.
python - <<'PYEOF'
from pathlib import Path
import sysconfig
root = Path(sysconfig.get_paths()["purelib"])
audio = root / "faster_whisper" / "audio.py"
if "f32le" not in audio.read_text(encoding="utf-8"):
    audio.write_text('''"""Audio decoding via the app/bundled ffmpeg binary (no PyAV needed).

faster-whisper normally decodes audio with PyAV, but PyAV macOS x86_64 wheels
ship dylibs whose Mach-O headers have no room for the load-command rewrites that
py2app/macholib performs, so PyAV cannot be bundled. This app already decodes
all media with its own static ffmpeg, so we implement decode_audio with a
plain ffmpeg subprocess call instead.

Set WHISPER_FFMPEG to the bundled binary path (whisper_gui.pyw does this);
otherwise a system ffmpeg on PATH is used as a fallback.
"""
import os
import shutil
import subprocess
import tempfile

import numpy as np


def _find_ffmpeg():
    return os.environ.get("WHISPER_FFMPEG") or shutil.which("ffmpeg")


def decode_audio(input_file, sampling_rate=16000, split_stereo=False):
    """Decodes the audio.

    Args:
      input_file: Path to the input file or a file-like object.
      sampling_rate: Resample the audio to this sample rate.
      split_stereo: Return separate left and right channels.

    Returns:
      A float32 Numpy array.

      If `split_stereo` is enabled, the function returns a 2-tuple with the
      separated left and right channels.
    """
    ffmpeg = _find_ffmpeg()
    if not ffmpeg:
        raise RuntimeError(
            "FFmpeg was not found. It should be next to this program or "
            "installed on the system (set WHISPER_FFMPEG to its path).")

    temp_path = None
    target = input_file
    if not isinstance(input_file, str):
        fd, temp_path = tempfile.mkstemp(prefix="whisper_audio_", suffix=".wav")
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(input_file.read())
        except OSError:
            pass
        target = temp_path

    try:
        channels = "2" if split_stereo else "1"
        cmd = [ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(target),
               "-map", "a:0", "-ac", channels, "-ar", str(sampling_rate),
               "-f", "f32le", "-"]
        result = subprocess.run(cmd, capture_output=True)
        if result.returncode != 0:
            raise RuntimeError(
                "FFmpeg failed to decode the audio track.\\n\\n" +
                (result.stderr.decode("utf-8", "replace") or "")[-800:])
        audio = np.frombuffer(result.stdout, dtype=np.float32)
        if split_stereo:
            return audio[0::2], audio[1::2]
        return audio
    finally:
        if temp_path is not None:
            try:
                os.remove(temp_path)
            except OSError:
                pass


def pad_or_trim(array, length: int = 3000, *, axis: int = -1):
    """
    Pad or trim the Mel features array to 3000, as expected by the encoder.
    """
    if array.shape[axis] > length:
        array = array.take(indices=range(length), axis=axis)

    if array.shape[axis] < length:
        pad_widths = [(0, 0)] * array.ndim
        pad_widths[axis] = (0, length - array.shape[axis])
        array = np.pad(array, pad_widths)

    return array
''', encoding="utf-8")
    print("  patched faster_whisper/audio.py (ffmpeg-based decode, no PyAV)")
PYEOF

# Argos Translate has occasional open()/read() calls without an explicit
# encoding.  On ASCII-only locales (Hackintoshes) those crash decoding UTF-8
# package metadata; force UTF-8 on every one of them.
python - <<'PYEOF'
from pathlib import Path
import sysconfig
root = Path(sysconfig.get_paths()["purelib"])
fixes = [
    ("argostranslate/package.py",
     'with open(metadata_path) as metadata_file:',
     'with open(metadata_path, encoding="utf-8") as metadata_file:'),
    ("argostranslate/package.py",
     'with open(readme_path, "r") as readme_file:',
     'with open(readme_path, "r", encoding="utf-8") as readme_file:'),
    ("argostranslate/package.py",
     'with open(settings.local_package_index) as index_file:',
     'with open(settings.local_package_index, encoding="utf-8") as index_file:'),
    ("argostranslate/settings.py",
     'with open(settings_file, "r") as settings_file_data:',
     'with open(settings_file, "r", encoding="utf-8") as settings_file_data:'),
    ("argostranslate/settings.py",
     'with open(settings_file, "w") as settings_file_data:',
     'with open(settings_file, "w", encoding="utf-8") as settings_file_data:'),
]
for rel, old, new in fixes:
    p = root / rel
    src = p.read_text(encoding="utf-8")
    if old not in src:
        raise SystemExit(f"argostranslate {rel}: pattern changed upstream:\n  {old}")
    if new not in src:
        p.write_text(src.replace(old, new, 1), encoding="utf-8")
        print(f"  patched {rel} (explicit utf-8)")
PYEOF

# Renaming the modulegraph walker (used by py2app) resolves namespace
# packages with imp.find_module, which fails on namespace packages that have
# no __init__.py. protobuf ships google/ as a pure namespace package; give it
# a marker init so the walker can follow google.protobuf into the bundle.
python - <<'PYEOF'
from pathlib import Path
import sysconfig
root = Path(sysconfig.get_paths()["purelib"])
google_init = root / "google" / "__init__.py"
if not google_init.exists():
    google_init.write_text("# marker file to turn the google namespace package "
                           "into a regular package\n", encoding="utf-8")
    print("  created google/__init__.py marker")
else:
    print("  google/__init__.py already present")
PYEOF

log "Bundling a static ffmpeg binary"
FFMPEG_DIR="$MAC_DIR/ffmpeg_mac"
rm -rf "$FFMPEG_DIR"
mkdir -p "$FFMPEG_DIR"
# Always try the official static build first: the app must run on machines
# without ffmpeg, and a Homebrew/system binary links against dylibs that would
# not be bundled. Fall back to a system binary only if the download fails.
log "  downloading static ffmpeg ($FFMPEG_URL)"
if curl -fsSL "$FFMPEG_URL" -o /tmp/ffmpeg_mac.zip; then
    unzip -o -j /tmp/ffmpeg_mac.zip -d "$FFMPEG_DIR"
    rm -f /tmp/ffmpeg_mac.zip
else
    rm -f /tmp/ffmpeg_mac.zip
    if command -v ffmpeg >/dev/null 2>&1; then
        echo "  (static download failed; falling back to system ffmpeg)"
        cp "$(command -v ffmpeg)" "$FFMPEG_DIR/ffmpeg" 2>/dev/null || true
    fi
fi
[ -x "$FFMPEG_DIR/ffmpeg" ] || die "ffmpeg not available. Install it (brew install ffmpeg) or set FFMPEG_URL."
chmod +x "$FFMPEG_DIR/ffmpeg"
"$FFMPEG_DIR/ffmpeg" -version >/dev/null 2>&1 || die "bundled ffmpeg does not run (wrong CPU arch?)"
# Require a self-contained binary (static ffmpeg links only system frameworks).
if otool -L "$FFMPEG_DIR/ffmpeg" 2>/dev/null | grep -qE '/usr/local|/opt/homebrew'; then
    die "bundled ffmpeg links Homebrew dylibs; set FFMPEG_URL to a static build."
fi

log "Building the .app bundle with py2app"
rm -rf "$MAC_DIR/build" "$MAC_DIR/dist"
mkdir -p "$MAC_DIR"
cp "$ROOT_DIR/whisper_gui.pyw" "$MAC_DIR/whisper_gui.py"
# the .pyw is the canonical source; keep the local copy in sync
(cd "$MAC_DIR" && python setup.py py2app)

APP="$MAC_DIR/dist/Whisper Subtitler.app"
[ -d "$APP" ] || die "py2app did not produce $APP"

# Ad-hoc codesign: required for the bundle to launch on modern macOS
# (unsigned .app bundles are often rejected by Gatekeeper).
log "Ad-hoc codesigning the bundle"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"

log "Validating architecture"
file "$APP/Contents/MacOS/WhisperSubtitler" 
echo "  -> arch: $(file "$APP/Contents/MacOS/WhisperSubtitler" | grep -oE 'x86_64|arm64' | head -1)"

log "Creating installer DMG"
STAGE="$MAC_DIR/dmg_stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applicazioni"
cat > "$STAGE/LeggiMe.txt" <<'EOF'
WHISPER SUBTITLER
================

COME INSTALLARE
1. Trascina "Whisper Subtitler" nella cartella "Applicazioni".
2. Apri il Finder, vai su Applicazioni e fai doppio clic su "Whisper Subtitler".

AL PRIMO AVVIO (importante)
macOS potrebbe dire "Whisper Subtitler non può essere aperto perché
proviene da uno sviluppatore non identificato". È normale: il programma
non è firmato da Apple.

Per aprirlo comunque:
- tasto destro sul programma  ->  Apri  ->  Apri di nuovo

CONNESSIONE INTERNET
Al primo utilizzo serve internet per scaricare il modello di
riconoscimento vocale (viene salvato nella cartella dell'applicazione).
Dopo di che può funzionare anche offline.

DISINSTALLAZIONE
Basta trascinare "Whisper Subtitler" nel Cestino.
EOF
hdiutil create -volname "Whisper Subtitler" -srcfolder "$STAGE" \
    -ov -format UDZO "$MAC_DIR/dist/WhisperSubtitler_Mac.dmg"

log "Cleaning build artifacts"
rm -rf "$STAGE" "$MAC_DIR/build" "$MAC_DIR/whisper_gui.py"

echo
echo "FATTO."
echo "   - App  : $APP"
echo "   - DMG  : $MAC_DIR/dist/WhisperSubtitler_Mac.dmg"
du -sh "$APP" "$MAC_DIR/dist/WhisperSubtitler_Mac.dmg" 2>/dev/null || true
echo
echo "Per avviare subito senza DMG:  open \"$APP\""