# Whisper Subtitler — macOS build

Builds the standalone `Whisper Subtitler.app` bundle and the
`WhisperSubtitler_Mac.dmg` installer with **py2app**.

Both the app and the build script are at the repository root so the GUI source
(`whisper_gui.pyw`) is shared between the Windows and macOS packages.

```bash
tools/build_mac.sh
```

Outputs:

- `mac/dist/Whisper Subtitler.app` — the drag-and-drop app
- `mac/dist/WhisperSubtitler_Mac.dmg` — the installer image

See **Part 3** of the main `README.md` for end-user instructions and build
requirements (macOS 10.15+ x86_64, Xcode CLT, framework Python 3.11/3.12,
`python-tk@3.12`).

## Notes learned the hard way

Do **not** undo these without re-testing the bundle:

1. **py2app does not follow lazy/conditional pure-Python imports.** Transitive
   dependencies such as `tqdm`, `httpx`, `huggingface_hub` deps and
   `onnxruntime` get silently dropped. They are listed explicitly in
   `mac/setup.py` (`OPTIONAL` + `find_spec`) — keep the list in sync when
   bumping a dependency.
2. **Namespace package `google`.** protobuf ships `google/` without an
   `__init__.py`; py2app's modulegraph cannot walk it. `tools/build_mac.sh`
   creates `google/__init__.py` in the venv before building.
3. **onnxruntime is required** even though nothing imports it directly:
   `minisbd` (Argos Translate sentence splitter) imports it at load time.
4. **ffmpeg goes inside the bundle** (`Resources/ffmpeg`, copied via
   `mac/setup.py` `resources`) and is referenced by `WHISPER_FFMPEG`. Use a
   static build, never a Homebrew binary (its dylibs are not bundled).
5. **PyAV cannot be bundled on macOS x86_64** (macholib cannot relocate its
   dylibs). `tools/build_mac.sh` replaces `faster_whisper/audio.py` with a
   plain ffmpeg subprocess decoder, and guards the `stanza` import in
   `argostranslate/sbd.py` so PyTorch (~2 GB) stays out.
6. **ASCII-only locales** (common on Hackintoshes) crash libraries that
   `open()` UTF-8 files without an explicit encoding. The build patches
   `argostranslate` to force `encoding="utf-8"`, sets `PYTHONUTF8=1` in the
   app plist, and `whisper_gui.pyw` forces a UTF-8 locale + stream
   reconfigure on `darwin` at startup.
