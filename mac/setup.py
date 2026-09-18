#!/usr/bin/env python3
"""py2app build configuration for the macOS Whisper Subtitler .app bundle.

Run from the mac/ directory after creating the build virtual environment
(see tools/build_mac.sh). Requires a framework Python (python.org or
Homebrew), x86_64 on the Intel Hackintosh.
"""

import os
import sys

# modulegraph walks the AST of every imported module to find hidden imports;
# some dependencies (e.g. tokenizers, C-extensions with generated code) are
# nested deeply enough to hit CPython's default recursion limit.
sys.setrecursionlimit(10000)

APP = ["whisper_gui.py"]

# These must never enter the bundle. Argos Translate hard-imports stanza
# (-> torch ~2 GB) unless guarded; the app patches argostranslate/sbd.py and
# disables the stanza chunker. onnxruntime IS required though: minisbd (the
# sentence-boundary detector used by argostranslate) imports it at module load.
EXCLUDES = [
    "torch",
    "stanza",
    "spacy",
    "thinc",
    "blis",
]

# The runtime closure of the app:
#   whisper  : faster_whisper -> ctranslate2, tokenizers, tqdm, huggingface_hub
#              hub -> httpx/httpcore/h11/anyio/sniffio/idna/certifi, fsspec,
#              requests/urllib3/certifi, filelock, yaml
#   translate: argostranslate -> ctranslate2, minisbd, sentencepiece,
#              sacremoses, google.protobuf (via sentencepiece _pb2)
#   shared   : numpy, regex, charset_normalizer, click, emoji
# Bumping huggingface_hub? Add the new transitive pure-Python deps here: py2app's
# modulegraph does NOT follow lazy/conditional pure-Python imports (it silently
# dropped tqdm and httpx) so they must be listed explicitly.
OPTIONAL = [
    "faster_whisper",
    "ctranslate2",
    "tokenizers",
    "tqdm",
    "huggingface_hub",
    "httpx",
    "httpcore",
    "h11",
    "anyio",
    "sniffio",
    "idna",
    "certifi",
    "httpx_sse",
    "fsspec",
    "requests",
    "urllib3",
    "charset_normalizer",
    "filelock",
    "yaml",
    "typing_extensions",
    "numpy",
    "regex",
    "click",
    "emoji",
    "argostranslate",
    "minisbd",
    "sentencepiece",
    "sacremoses",
    "google",
    "protobuf",
    "onnxruntime",
    "coloredlogs",
    "humanfriendly",
    "flatbuffers",
    "packaging",
]

# Keep only the ones actually installed in this venv (resilient to version
# churn) so py2app never fails on a stale entry.
from importlib.util import find_spec

REQUIRED_PACKAGES = [p for p in OPTIONAL if find_spec(p) is not None]

# The static ffmpeg binary is copied next to the bundle as Contents/Resources.
RESOURCES = []
MAC_DIR = os.path.dirname(os.path.abspath(__file__))

FFMPEG_DIR = os.path.join(MAC_DIR, "ffmpeg_mac")
FFMPEG_BIN = os.path.join(FFMPEG_DIR, "ffmpeg")
if os.path.isfile(FFMPEG_BIN):
    # distutils data_files convention: (dest_dir, [source_files...]) -> the
    # static binary lands in Contents/Resources/ffmpeg/ffmpeg.
    RESOURCES.append(("ffmpeg", [FFMPEG_BIN]))

ICNS = os.path.join(MAC_DIR, "assets_mac", "icon.icns")

PLIST = {
    "CFBundleName": "Whisper Subtitler",
    "CFBundleDisplayName": "Whisper Subtitler",
    "CFBundleIdentifier": "com.whispersubtitler.app",
    "CFBundleShortVersionString": "2.0",
    "CFBundleVersion": "2.0",
    "CFBundleExecutable": "WhisperSubtitler",
    "NSHighResolutionCapable": True,
    "NSQuitAlwaysKeepsWindows": True,
    "NSHumanReadableCopyright": "Whisper Subtitler",
    # Force the UTF-8 codec for every text open()/read() in the bundle.
    # Without this, an ASCII-only system locale (common on Hackintoshes) makes
    # libraries that open() JSON/data files without an explicit encoding crash
    # with "'ascii' codec can't decode byte ..." errors.
    "LSEnvironment": {"PYTHONUTF8": "1"},
}

OPTIONS = {
    "argv_emulation": False,
    "packages": REQUIRED_PACKAGES,
    "excludes": EXCLUDES,
    "resources": RESOURCES,
    "plist": PLIST,
}

if os.path.isfile(ICNS):
    OPTIONS["iconfile"] = ICNS

if __name__ == "__main__":
    print("Packages bundled:", ", ".join(REQUIRED_PACKAGES))

setup = __import__("setuptools").setup
setup(
    name="WhisperSubtitler",
    app=APP,
    options={"py2app": OPTIONS},
)