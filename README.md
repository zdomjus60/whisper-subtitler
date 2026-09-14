# Whisper Subtitler

Generate `.srt` subtitle files from any video using speech recognition (Whisper),
optimized for CPU. Available as:

- a command-line Python script (`whisper_subtitler.py`) for Debian/Linux, and
- a ready-to-run **portable Windows app** (`WhisperSubtitler.exe`) bundled with
  Python, ffmpeg and faster-whisper, ready for non-technical users.

---

## Part 1 — Windows portable app (all-in-one)

### What the end user gets

Two distribution options, both produced by the build:

- **`WhisperSubtitler_Setup.exe`** — a self-installing setup wizard.
  Recommended for non-technical users: double-click, press Next, and a shortcut
  is created on the Desktop and in the Start Menu. No zip knowledge required.
- `WhisperSubtitler.zip` (~150 MB) — portable folder, extract and run.

### End-user experience

1. Double-click **`WhisperSubtitler_Setup.exe`**.
2. Follow the wizard (press *Next*). The program installs for the
   current user in `%LOCALAPPDATA%\Whisper Subtitler` (no administrator
   rights needed).
3. A shortcut appears on the **Desktop**: double-click **Whisper Subtitler**.
4. A splash screen appears, then the main window.
5. Choose the video file and the output subtitle path. The automatic output
   name includes the selected language, e.g. `video.it.srt`; with
   *Auto-detect* the name uses the actually detected language
   (e.g. `video.en.srt`).
6. Choose the **subtitle (target) language** (`Automatic detection`, English,
   Italiano, Français, Español, Deutsch, Português, Nederlands, Polski,
   Русский, Türkçe, Ελληνικά, العربية, Hindi, 中文, 日本語, 한국어) and the
   model size (`tiny`, `base`, `small`, `medium`, `large-v3`).
7. Click **Generate SRT Subtitles** and wait. The log panel shows each step.
8. The `.srt` file is written next to the video.

### Translation

The selected language in step 6 is the **language of the generated subtitles**:

- The speech is always detected automatically.
- If the selected language differs from the detected one, the subtitles are
  translated **locally** with Argos Translate. Direct pairs are used when
  available, otherwise the text is pivoted through English
  (e.g. `it → fr` is performed as `it → en → fr`).
- Translation packages are **downloaded on demand on first use** (only the
  languages you actually use), and stored in the `translations/` folder in the
  app directory, so everything stays offline afterwards.

To remove the program, use *Uninstall* from the Start Menu (or Uninstall.exe).

Requirements: **Windows 10/11 64-bit** and internet **on the first run only**
(to download the Whisper model and any translation package actually used; both
are stored in the app directory). No installation, no admin rights, no PATH
setup.

### Building the Windows package (on Debian)

The build fully runs on a Debian machine. Requirements:

- `curl`, `unzip`
- `x86_64-w64-mingw32-gcc` (mingw-w64)
- `python3` with pip
- `wine` (to extract Tcl/Tk from the official `tcltk.msi`)
- `makensis` + NSIS data files (`nsis`, `nsis-common` Debian packages, or the
  extracted files with `NSISDIR` pointing at the `usr/share/nsis` folder) to
  build the installer; if missing, the installer is skipped

```bash
./build_package.sh
```

Output:

- `dist/WhisperSubtitler/` — ready-to-run folder
- `WhisperSubtitler.zip` — distributable archive
- `WhisperSubtitler_Setup.exe` — self-installing wizard (if NSIS is present)

---

## Part 2 — Command-line script (`whisper_subtitler.py`)

The original Linux script, kept for completeness and as reference.

### Prerequisites

```bash
sudo apt update && sudo apt install ffmpeg
python3 -m venv whisper-env && source whisper-env/bin/activate
pip install faster-whisper
```

### Usage

```bash
python whisper_subtitler.py <video_path> <srt_path> [--language <code>] [--model <name>]
```

Example:

```bash
python whisper_subtitler.py movie.mp4 movie.srt --language en --model small
```

The script (and the Windows app) follow the same pipeline:

1. Extract the audio track with ffmpeg.
2. Transcribe it with faster-whisper (CPU, `int8`), requesting word-level
   timestamps.
3. Write the SRT file, sizing each line to ~42 display columns. CJK scripts
   (Japanese, Chinese, Korean) are joined without spaces so they stay
   readable even though Whisper emits character-level words.
4. Delete the temporary audio file.