#!/usr/bin/env python3
"""Whisper Subtitler - desktop GUI to generate .srt subtitles from videos."""

import os
import queue
import re
import shutil
import sys
import tempfile
import threading
import subprocess
from datetime import timedelta

if sys.platform == "darwin":
    # On Hackintoshes the shell/launchd locale is often ASCII-only (C/POSIX).
    # In that case any `open()`/read() without an explicit encoding decodes
    # UTF-8 as ASCII and crashes with "'ascii' codec can't decode byte ...".
    # The old guard (`getfilesystemencodeerrors() != "surrogateescape"`) never
    # fired on macOS because that value is ALWAYS "surrogateescape" there, so
    # the locale fix was silently skipped.  On Python 3.11+ calling setlocale
    # at runtime DOES change what open() uses as the default text encoding, so
    # we force a UTF-8 locale unconditionally here.
    import locale
    for _enc in ("it_IT.UTF-8", "en_US.UTF-8", "C.UTF-8"):
        try:
            locale.setlocale(locale.LC_ALL, _enc)
            break
        except locale.Error:
            continue
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

import tkinter as tk
from tkinter import ttk, filedialog, messagebox

# Build marker so the user can tell the fixed bundle apart from old ones.
APP_VERSION = "2.0"

if sys.platform == "darwin":
    # Inside a py2app bundle RESOURCEPATH points at Contents/Resources.
    APP_DIR = os.environ.get("RESOURCEPATH", os.path.dirname(os.path.abspath(__file__)))
    # Keep runtime data (models, translations) in the user's Library so the
    # app stays usable whether the .app sits in /Applications or elsewhere.
    _DATA_DIR = os.path.join(
        os.path.expanduser("~"), "Library", "Application Support", "Whisper Subtitler")
    os.makedirs(_DATA_DIR, exist_ok=True)
elif getattr(sys, "frozen", False) and sys.platform == "linux":
    # PyInstaller bundle: the app folder is mounted read-only inside an
    # AppImage, so keep runtime data (models, translations) in the user's
    # home instead (XDG base dirs).
    APP_DIR = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    _DATA_DIR = os.path.join(
        os.environ.get("XDG_DATA_HOME", os.path.join(os.path.expanduser("~"), ".local", "share")),
        "Whisper Subtitler")
    os.makedirs(_DATA_DIR, exist_ok=True)
else:
    APP_DIR = os.path.dirname(os.path.abspath(__file__))
    _DATA_DIR = APP_DIR

MODELS_DIR = os.path.join(_DATA_DIR, "models")


def default_dialogs_dir():
    """Return the Desktop folder, or the home dir as a fallback.

    Without this the file dialogs open on the last folder used by Windows,
    which confuses non-technical users.
    """
    if sys.platform != "win32":
        # Honor localized desktop names via xdg-user-dirs (e.g. "Scrivania"
        # on Italian locales).
        try:
            with open(os.path.join(os.path.expanduser("~"), ".config", "user-dirs.dirs"),
                      encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("XDG_DESKTOP_DIR="):
                        value = line.split("=", 1)[1].strip().strip('"')
                        value = value.replace("$HOME", os.path.expanduser("~"))
                        if os.path.isdir(value):
                            return value
        except OSError:
            pass
    desktop = os.path.join(os.path.expanduser("~"), "Desktop")
    if os.path.isdir(desktop):
        return desktop
    return os.path.expanduser("~")

# --- Dark theme palette ---
BG = "#1e1e28"            # main background
PANEL = "#2b2b3d"         # inputs background
PANEL_BUTTON = "#34344a"  # buttons background
PANEL_ACTIVE = "#3d3d58"  # hover
PANEL_DISABLED = "#242434"
OUTLINE = "#3f3f5c"
FG = "#e0e0ea"            # normal text
MUTED = "#a5a9c0"         # secondary text
LOG_BG = "#14141c"
LOG_FG = "#c9cddb"
ACCENT = "#5b8def"
ACCENT_ACTIVE = "#7aa2f7"
ACCENT_DISABLED = "#3a558f"
GOLD = "#e6b84c"

if sys.platform == "darwin":
    FONT_FAMILY = "Helvetica Neue"
elif sys.platform == "linux":
    FONT_FAMILY = "DejaVu Sans"
else:
    FONT_FAMILY = "Segoe UI"

os.environ.setdefault("HUGGINGFACE_HUB_DISABLE_PROGRESS_BARS", "1")

LANGUAGES = [
    ("Auto-detect", ""),
    ("English", "en"),
    ("Italiano", "it"),
    ("Français", "fr"),
    ("Español", "es"),
    ("Deutsch", "de"),
    ("Português", "pt"),
    ("Nederlands", "nl"),
    ("Polski", "pl"),
    ("Русский", "ru"),
    ("Türkçe", "tr"),
    ("Ελληνικά", "el"),
    ("العربية", "ar"),
    ("Hindi", "hi"),
    ("中文", "zh"),
    ("日本語", "ja"),
    ("한국어", "ko"),
]

MODELS = [
    ("tiny  (fastest, ~75 MB)", "tiny"),
    ("base  (~150 MB)", "base"),
    ("small  (recommended, ~500 MB)", "small"),
    ("medium  (~1.5 GB)", "medium"),
    ("large-v3  (highest accuracy, ~3 GB)", "large-v3"),
]

VIDEO_EXTENSIONS = (
    ".mp4", ".mkv", ".webm", ".avi", ".mov", ".flv", ".wmv",
    ".m4v", ".ts", ".mpg", ".mpeg", ".ogg", ".ogv",
)

# Progress phases (0..1).  Transcription and translation fill a band
# while they run; the small steps sit at fixed percentages.
P_EXTRACT = 0.05
P_MODEL = 0.10
P_TRANS_START = 0.15
P_TRANS_END = 0.80
P_BUILD = 0.82
P_TRANSLATE_START = 0.85
P_TRANSLATE_END = 0.97
P_WRITE = 0.98


def find_ffmpeg():
    """Return the ffmpeg executable bundled with the app, or one found on PATH."""
    for candidate in (
        os.path.join(APP_DIR, "ffmpeg"),
        os.path.join(APP_DIR, "ffmpeg", "ffmpeg.exe"),
        os.path.join(APP_DIR, "ffmpeg", "ffmpeg"),
    ):
        if os.path.isfile(candidate):
            return candidate
    return shutil.which("ffmpeg")


def get_audio_duration(ffmpeg, audio_path):
    """Return the media duration in seconds, or *None* on failure."""
    try:
        result = subprocess.run(
            [ffmpeg, "-i", audio_path], capture_output=True,
            text=True, encoding="utf-8", errors="replace")
        match = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)",
                          result.stderr or "")
        if not match:
            return None
        h, m, s = (float(g) for g in match.groups())
        return h * 3600 + m * 60 + s
    except Exception:
        return None


def format_timestamp(seconds):
    td = timedelta(seconds=seconds)
    total_seconds = int(td.total_seconds())
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    milliseconds = td.microseconds // 1000
    return "{:02d}:{:02d}:{:02d},{:03d}".format(hours, minutes, seconds, milliseconds)


def extract_audio(ffmpeg, video_path, audio_path, log):
    log("Extracting the audio track...")
    cmd = [ffmpeg, "-y", "-i", video_path, "-map", "a", "-ac", "2", "-q:a", "0", audio_path]
    result = subprocess.run(cmd, capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    if result.returncode != 0:
        hint = ""
        text = (result.stderr or result.stdout or "")[-800:]
        if "contains a stream with an unsupported format" in text or "could not be opened" in text:
            hint = "\n\nThe video may not have an audio track."
        raise RuntimeError("FFmpeg failed to extract the audio track." + hint + "\n\n" + text)


def create_model(model_name, log):
    from faster_whisper import WhisperModel
    log("Preparing model '{}' (downloaded automatically on first use)...".format(model_name))
    return WhisperModel(model_name, device="cpu", compute_type="int8", download_root=MODELS_DIR)


def transcribe(model, audio_path, log):
    log("Model ready. Detecting language and transcribing (CPU, this takes a while)...")
    segments, info = model.transcribe(
        audio_path,
        language=None,  # always auto-detect: the real source language is needed for translation
        beam_size=5,
        word_timestamps=True,
    )
    log("Detected language: {} (confidence {:.2f})".format(info.language, info.language_probability))
    return segments, info.language


# --- Translation engine (Argos Translate, offline after first download) ---

TRANSLATIONS_DIR = os.path.join(_DATA_DIR, "translations")


def _ensure_argos_env():
    """Keep all Argos data (packages, index, models) inside the app folder."""
    os.environ.setdefault("ARGOS_PACKAGES_DIR", os.path.join(TRANSLATIONS_DIR, "packages"))
    os.environ.setdefault("XDG_DATA_HOME", TRANSLATIONS_DIR)
    os.environ.setdefault("XDG_CACHE_HOME", os.path.join(TRANSLATIONS_DIR, "cache"))
    os.environ.setdefault("XDG_CONFIG_HOME", os.path.join(TRANSLATIONS_DIR, "config"))
    os.environ.setdefault("ARGOS_DEVICE_TYPE", "cpu")
    # Disable stanza entirely (would require torch ~2GB); Argos falls back to
    # MiniSBD for sentence boundary detection and to en-pivoting for missing pairs.
    os.environ.setdefault("ARGOS_STANZA_AVAILABLE", "0")


def _argos_installed_pairs():
    from argostranslate import translate as _at
    pairs = set()
    for lang in _at.get_installed_languages():
        for tr in lang.translations_from:
            pairs.add((lang.code, tr.to_lang.code))
    return pairs


def _install_argos_pair(from_code, to_code, log):
    """Download + install a translation package on first use. Returns True on success."""
    import argostranslate.package as apkg
    from argostranslate import translate as at
    log("Downloading translator {} → {} (first time, requires an internet connection)...".format(
        from_code, to_code))
    try:
        available = apkg.get_available_packages()
    except FileNotFoundError:
        apkg.update_package_index()
        available = apkg.get_available_packages()
    found = next((p for p in available if p.from_code == from_code and p.to_code == to_code), None)
    if found is None:
        log("Package {} → {} is not available in the Argos index.".format(from_code, to_code))
        return False
    apkg.install_from_path(found.download())
    at.get_installed_languages.cache_clear()
    log("Translator {} → {} installed.".format(from_code, to_code))
    return True


def _available_pairs_map():
    """Return {(from_code, to_code): package} for every package in the online index."""
    import argostranslate.package as apkg
    try:
        available = apkg.get_available_packages()
    except Exception:
        apkg.update_package_index()
        available = apkg.get_available_packages()
    return {(p.from_code, p.to_code): p for p in available}


def ensure_translation_legs(source_code, target_code, log):
    """Build the list of translation legs needed (direct pair or English pivot).

    Returns a list like [('en', 'it')] or [('ja', 'en'), ('en', 'it')].
    Raises RuntimeError if the required packages are missing and cannot be downloaded.
    """
    _ensure_argos_env()
    from argostranslate import translate as at

    available = _available_pairs_map()
    installed = _argos_installed_pairs()

    def has_pair(f, t):
        return (f, t) in installed or (f, t) in available

    # Prefer the direct pair when it exists; otherwise pivot via English.
    if has_pair(source_code, target_code):
        legs = [(source_code, target_code)]
    elif source_code != "en" and target_code != "en" \
            and has_pair(source_code, "en") and has_pair("en", target_code):
        legs = [(source_code, "en"), ("en", target_code)]
    elif (source_code, target_code) == ("en", "en"):
        legs = []
    else:
        raise RuntimeError(
            "Translation not possible: no translation pair available "
            "for '{} → {}' in the Argos index.\n\n"
            "Please choose a different language.".format(source_code, target_code))

    for f, t in legs:
        if (f, t) not in installed:
            if not _install_argos_pair(f, t, log):
                raise RuntimeError(
                    "Translation not possible: the {} → {} translation package "
                    "is missing and could not be downloaded.\n\n"
                    "Check your internet connection (translation models are "
                    "downloaded on first use) or choose a different language.".format(f, t))
    return legs


def translate_entries(entries, source_code, target_code, log, progress=None):
    """Translate subtitle entries to the target language, keeping timestamps.

    entries: list of (start, end, text). Returns the same structure with
    translated text.  ``progress(label, fraction)`` is invoked per entry.
    """
    _ensure_argos_env()
    from argostranslate import translate as at
    legs = ensure_translation_legs(source_code, target_code, log)
    route = " → ".join("{}→{}".format(f, t) for f, t in legs)
    log("Translating {}: {} (subtitles may be reflowed during translation)...".format(
        target_code, route))
    translated_entries = []
    total = len(entries)
    for i, (start, end, text) in enumerate(entries, start=1):
        if progress is not None:
            frac = i / total if total else 1.0
            progress("Translating {} / {}".format(i, total),
                     P_TRANSLATE_START + (P_TRANSLATE_END - P_TRANSLATE_START) * frac)
        out = text
        for f, t in legs:
            out = at.translate(out, f, t)
        translated_entries.append((start, end, out))
    log("Translation complete.")
    return translated_entries


def _is_wide_char(ch):
    """True for CJK / fullwidth characters that render ~2 columns wide.

    Needed to size subtitle lines correctly for scripts without spaces
    (Japanese, Chinese, Korean), where Whisper emits character-level words.
    """
    cp = ord(ch)
    if 0x1100 <= cp <= 0x11FF:      # Hangul Jamo
        return True
    if 0x2E80 <= cp <= 0x303F:      # CJK radicals, punctuation
        return True
    if 0x3040 <= cp <= 0x30FF:      # Hiragana, Katakana
        return True
    if 0x3400 <= cp <= 0x4DBF:      # CJK Extension A
        return True
    if 0x4E00 <= cp <= 0x9FFF:      # CJK Unified Ideographs
        return True
    if 0xA960 <= cp <= 0xA97F:      # Hangul Jamo Extended-A
        return True
    if 0xAC00 <= cp <= 0xD7A3:      # Hangul syllables
        return True
    if 0xF900 <= cp <= 0xFAFF:      # CJK Compatibility Ideographs
        return True
    if 0xFE30 <= cp <= 0xFE4F:      # CJK Compatibility Forms
        return True
    if 0xFF00 <= cp <= 0xFFEF:      # Fullwidth forms
        return True
    return False


def _char_width(ch):
    return 2 if _is_wide_char(ch) else 1


def build_entries(segments, max_width=42, duration=None, progress=None):
    """Group the transcribed words into subtitle entries (start, end, text).

    Lines are sized by display width (a CJK character counts as two
    columns) instead of by word count, so space-less scripts produce
    readable lines too. CJK characters are joined without spaces.

    ``segments`` is a lazy generator, so this function is where the actual
    transcription CPU work happens.  When ``duration`` is known, a
    ``progress(label, fraction)`` callback is invoked as segments are
    consumed to report a real percentage.
    """
    entries = []

    def line_text(parts):
        out = parts[0]
        for part in parts[1:]:
            prev_ch = out[-1]
            cur_ch = part[0]
            if _is_wide_char(prev_ch) and _is_wide_char(cur_ch):
                out += part
            else:
                out += " " + part
        return out

    for segment in segments:
        if progress is not None:
            if duration:
                frac = min(segment.end / duration, 1.0)
                progress("Transcribing {:.0%}".format(frac),
                         P_TRANS_START + (P_TRANS_END - P_TRANS_START) * frac)
            else:
                progress("Transcribing...", P_TRANS_START)
        words = list(segment.words or [])
        if not words:
            continue
        line_parts = []
        line_start = None
        line_end = None
        line_width = 0
        for i, word in enumerate(words):
            text = (word.word or "").strip()
            if not text:
                continue
            if line_start is None:
                line_start = word.start
            sep_cost = 0
            if line_parts:
                prev_ch = line_parts[-1][-1]
                cur_ch = text[0]
                sep_cost = 0 if (_is_wide_char(prev_ch) and _is_wide_char(cur_ch)) else 1
            word_width = sum(_char_width(c) for c in text)
            if line_parts and line_width + sep_cost + word_width > max_width:
                entries.append((line_start, line_end, line_text(line_parts)))
                line_parts = []
                line_start = word.start
                line_width = 0
                sep_cost = 0
            line_parts.append(text)
            line_width += sep_cost + word_width
            line_end = word.end
            last_word = i == len(words) - 1
            if last_word:
                entries.append((line_start, line_end, line_text(line_parts)))
    if not entries:
        raise RuntimeError("No words were transcribed. The audio may be silent or the language may be wrong.")
    return entries


def write_srt(entries, srt_path, log):
    log("Writing the SRT subtitle file...")
    with open(srt_path, "w", encoding="utf-8") as srt_file:
        for index, (start, end, text) in enumerate(entries, start=1):
            srt_file.write("{}\n".format(index))
            srt_file.write("{} --> {}\n".format(
                format_timestamp(start), format_timestamp(end)))
            srt_file.write(text + "\n\n")
    log("Subtitles written: {} entries".format(len(entries)))


def process_video(video_path, srt_path, language, model_name, log, progress, auto_output=False):
    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        raise RuntimeError(
            "FFmpeg was not found. It should be in the 'ffmpeg' folder next "
            "to this program, or installed on the system.")
    os.environ["WHISPER_FFMPEG"] = ffmpeg
    log("FFmpeg found: {}".format(os.path.basename(ffmpeg)))

    temp_dir = tempfile.mkdtemp(prefix="whisper_sub_")
    audio_path = os.path.join(temp_dir, "audio.wav")
    srt_path = os.path.abspath(srt_path)
    try:
        progress("Extracting the audio track...", P_EXTRACT)
        extract_audio(ffmpeg, video_path, audio_path, log)
        duration = get_audio_duration(ffmpeg, audio_path)

        progress("Preparing the model...", P_MODEL)
        model = create_model(model_name, log)

        progress("Transcribing... (takes a while)", P_TRANS_START)
        segments, detected_lang = transcribe(model, audio_path, log)

        # With "Auto-detect" name the output after the language that was
        # actually detected (e.g. video.en.srt).
        if auto_output and not language and detected_lang:
            base, _ = os.path.splitext(srt_path)
            srt_path = "{}.{}.srt".format(base, detected_lang)
            log("Output name using the detected language: {}".format(os.path.basename(srt_path)))

        progress("Building subtitle entries...", P_BUILD)
        entries = build_entries(segments, duration=duration, progress=progress)

        if language and language != detected_lang:
            progress("Translating to {}...".format(language), P_TRANSLATE_START)
            entries = translate_entries(entries, detected_lang, language,
                                        log, progress=progress)
        elif language:
            log("The selected language ({}) matches the video language: no translation needed.".format(language))

        progress("Writing the SRT file...", P_WRITE)
        write_srt(entries, srt_path, log)
        return srt_path
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def apply_dark_theme(root):
    root.configure(bg=BG)
    try:
        root.option_add("*TCombobox*Listbox.background", PANEL)
        root.option_add("*TCombobox*Listbox.foreground", FG)
        root.option_add("*TCombobox*Listbox.selectBackground", ACCENT)
        root.option_add("*TCombobox*Listbox.selectForeground", "#ffffff")
    except tk.TclError:
        pass

    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass

    style.configure(".", background=BG, foreground=FG, fieldbackground=PANEL,
                    troughcolor=PANEL, bordercolor=OUTLINE, focuscolor=ACCENT,
                    insertcolor=FG, selectbackground=ACCENT, selectforeground="#ffffff",
                    arrowcolor=FG, lightcolor=OUTLINE, darkcolor=OUTLINE, relief="flat")
    style.map(".", background=[("active", PANEL_ACTIVE), ("disabled", PANEL_DISABLED)],
              foreground=[("disabled", MUTED)])

    style.configure("TLabel", background=BG, foreground=FG)
    style.configure("Title.TLabel", font=(FONT_FAMILY, 14, "bold"), foreground=FG, background=BG)
    style.configure("Muted.TLabel", background=BG, foreground=MUTED)

    style.configure("TEntry", fieldbackground=PANEL, foreground=FG, insertcolor=FG,
                    bordercolor=OUTLINE, lightcolor=OUTLINE, darkcolor=OUTLINE)
    style.map("TEntry", fieldbackground=[("disabled", PANEL_DISABLED)])

    style.configure("TCombobox", fieldbackground=PANEL, background=PANEL, foreground=FG,
                    arrowcolor=FG, bordercolor=OUTLINE)
    style.map("TCombobox", fieldbackground=[("readonly", PANEL)],
              foreground=[("readonly", FG)],
              background=[("active", PANEL_ACTIVE)])

    style.configure("TButton", background=PANEL_BUTTON, foreground=FG, bordercolor=OUTLINE,
                    padding=(10, 4))
    style.map("TButton", background=[("active", PANEL_ACTIVE), ("disabled", PANEL_DISABLED)],
              foreground=[("disabled", MUTED)])

    style.configure("Accent.TButton", background=ACCENT, foreground="#ffffff",
                    bordercolor=ACCENT, padding=(10, 4))
    style.map("Accent.TButton",
              background=[("active", ACCENT_ACTIVE), ("disabled", ACCENT_DISABLED)],
              foreground=[("disabled", "#b8c6e8")])

    style.configure("TProgressbar", background=ACCENT_ACTIVE, troughcolor=PANEL,
                    bordercolor=BG, lightcolor=ACCENT_ACTIVE, darkcolor=ACCENT_ACTIVE)

    style.configure("Vertical.TScrollbar", background=PANEL_BUTTON, troughcolor=BG,
                    bordercolor=BG, arrowcolor=FG)
    style.map("Vertical.TScrollbar", background=[("active", PANEL_ACTIVE)])


class SubtitlerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Whisper Subtitler v" + APP_VERSION)
        self.root.resizable(False, False)
        self.queue = queue.Queue()
        self.busy = False
        self.auto_output = True

        apply_dark_theme(root)

        main = ttk.Frame(root, padding=16)
        main.grid(sticky="nsew")

        self.queue.put(("log", "Whisper Subtitler v{} starting...".format(APP_VERSION)))

        ttk.Label(main, text="Whisper Subtitler  v" + APP_VERSION, style="Title.TLabel").grid(
            row=0, column=0, columnspan=3, sticky="w", pady=(0, 2))
        ttk.Label(main, text="Generate .srt subtitles from any video file.",
                  style="Muted.TLabel").grid(
            row=1, column=0, columnspan=3, sticky="w", pady=(0, 12))

        # Video file
        ttk.Label(main, text="Video file:").grid(row=2, column=0, sticky="w", pady=3)
        self.video_var = tk.StringVar()
        ttk.Entry(main, textvariable=self.video_var, width=52).grid(row=2, column=1, pady=3, sticky="we")
        ttk.Button(main, text="Browse...", command=self.browse_video).grid(row=2, column=2, padx=(6, 0), pady=3)

        # Output SRT
        ttk.Label(main, text="Subtitle file:").grid(row=3, column=0, sticky="w", pady=3)
        self.output_var = tk.StringVar()
        ttk.Entry(main, textvariable=self.output_var, width=52).grid(row=3, column=1, pady=3, sticky="we")
        ttk.Button(main, text="Browse...", command=self.browse_output).grid(row=3, column=2, padx=(6, 0), pady=3)

        # Language (subtitle output language)
        ttk.Label(main, text="Subtitle language:").grid(row=4, column=0, sticky="w", pady=3)
        self.language_var = tk.StringVar(value="English")
        self.language_combo = ttk.Combobox(
            main, textvariable=self.language_var, state="readonly", width=50,
            values=[label for label, _ in LANGUAGES])
        self.language_combo.grid(row=4, column=1, columnspan=2, sticky="w", pady=3)
        self.language_combo.bind("<<ComboboxSelected>>", self._on_language_changed)

        # Model
        ttk.Label(main, text="Model:").grid(row=5, column=0, sticky="w", pady=3)
        self.model_var = tk.StringVar(value=MODELS[2][0])
        self.model_combo = ttk.Combobox(
            main, textvariable=self.model_var, state="readonly", width=50,
            values=[label for label, _ in MODELS])
        self.model_combo.grid(row=5, column=1, columnspan=2, sticky="w", pady=3)

        # Generate button
        self.generate_btn = ttk.Button(main, text="Generate SRT subtitles", command=self.start)
        self.generate_btn.grid(row=6, column=0, columnspan=3, sticky="we", pady=(12, 6))

        # Progress
        self.progress = ttk.Progressbar(main, mode="determinate", maximum=100,
                                        value=0, length=560)
        self.progress.grid(row=7, column=0, columnspan=3, sticky="we", pady=3)
        self.status_var = tk.StringVar(value="Ready.")
        ttk.Label(main, textvariable=self.status_var).grid(row=8, column=0, columnspan=3, sticky="w", pady=(0, 8))

        # Log
        self.log_text = tk.Text(main, width=72, height=14, state="disabled", wrap="word",
                                bg=LOG_BG, fg=LOG_FG, insertbackground=FG,
                                selectbackground=ACCENT, selectforeground="#ffffff",
                                relief="flat", borderwidth=0, padx=8, pady=8)
        self.log_text.grid(row=9, column=0, columnspan=3, sticky="we")
        scroll = ttk.Scrollbar(main, command=self.log_text.yview)
        scroll.grid(row=9, column=3, sticky="ns")
        self.log_text.configure(yscrollcommand=scroll.set)

        self.root.columnconfigure(0, weight=1)
        main.columnconfigure(1, weight=1)
        self.poll_queue()

    # ---- helpers ----
    def log(self, message):
        self.queue.put(("log", message))

    def status(self, text):
        self.queue.put(("status", text))

    def report_progress(self, label, fraction):
        """Queue a status update plus a determinate progress percentage."""
        self.status(label)
        try:
            self.queue.put(("progress", int(round(min(max(fraction, 0.0), 1.0) * 100))))
        except Exception:  # noqa: BLE001 - never let a progress update break the worker
            pass

    def done(self, srt_path):
        self.queue.put(("done", srt_path))

    def fail(self, message):
        self.queue.put(("error", message))

    def current_language_code(self):
        label = self.language_var.get()
        for lang_label, code in LANGUAGES:
            if lang_label == label:
                return code
        return "en"

    def _on_language_changed(self, _event=None):
        """Keep the automatic output name in sync with the chosen language."""
        if self.auto_output and self.video_var.get():
            self.output_var.set(self.default_srt_path(self.video_var.get()))

    def current_model_name(self):
        label = self.model_var.get()
        for model_label, name in MODELS:
            if model_label == label:
                return name
        return "small"

# ---- events ----
    def browse_video(self):
        path = filedialog.askopenfilename(
            title="Choose the video file",
            initialdir=default_dialogs_dir(),
            filetypes=[("Video files", "*" + " *".join(VIDEO_EXTENSIONS)),
                       ("All files", "*.*")])
        if not path:
            return
        self.video_var.set(path)
        if self.auto_output:
            self.output_var.set(self.default_srt_path(path))
        self.auto_output = True

    def default_srt_path(self, video_path):
        """Automatic output name: base.<language-iso>.srt (or base.srt when manual)."""
        base, _ = os.path.splitext(video_path)
        code = self.current_language_code()
        if code:
            return "{}.{}.srt".format(base, code)
        return base + ".srt"

    def browse_output(self):
        path = filedialog.asksaveasfilename(
            title="Save subtitles as...",
            initialdir=default_dialogs_dir(),
            defaultextension=".srt",
            filetypes=[("Subtitle files", "*.srt"), ("All files", "*.*")])
        if path:
            self.output_var.set(path)
            self.auto_output = False

    def start(self):
        if self.busy:
            return
        video = self.video_var.get().strip()
        if not video or not os.path.isfile(video):
            messagebox.showerror("No video",
                                 "Please choose a valid video file first.")
            return
        output = self.output_var.get().strip()
        if not output:
            output = self.default_srt_path(video)
            self.output_var.set(output)
        if os.path.abspath(output) == os.path.abspath(video):
            messagebox.showerror("Invalid output",
                                 "The subtitle file cannot be the same as the video file.")
            return

        self.busy = True
        self.generate_btn.config(state="disabled")
        self.progress["value"] = 0
        self.log_text.config(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.config(state="disabled")
        self.status("Working...")

        language = self.current_language_code()
        model_name = self.current_model_name()
        worker = threading.Thread(target=self.worker, args=(video, output, language, model_name, self.auto_output))
        worker.daemon = True
        worker.start()

    def worker(self, video, output, language, model_name, auto_output):
        try:
            final = process_video(video, output, language, model_name, self.log,
                                  self.report_progress, auto_output=auto_output)
            self.done(final)
        except Exception as exc:  # noqa: BLE001 - report all errors to the user
            # Persist the full traceback so failures can be diagnosed without
            # guessing (the on-screen message only shows str(exc)).
            try:
                import traceback
                import datetime
                _err_log = os.path.join(_DATA_DIR, "error.log")
                with open(_err_log, "a", encoding="utf-8") as _f:
                    _f.write("\n[{:%Y-%m-%d %H:%M:%S}] {}\n".format(
                        datetime.datetime.now(), video))
                    _f.write(traceback.format_exc())
                self.log("Detailed error saved to: " + _err_log)
            except Exception:  # noqa: BLE001 - never break error reporting
                pass
            self.fail(str(exc))

    def finish_ui(self):
        self.busy = False
        self.progress.stop()
        self.generate_btn.config(state="normal")

    # ---- queue polling ----
    def poll_queue(self):
        try:
            while True:
                kind, payload = self.queue.get_nowait()
                if kind == "log":
                    self.append_log(payload)
                elif kind == "status":
                    self.status_var.set(payload)
                elif kind == "progress":
                    self.progress["value"] = payload
                elif kind == "done":
                    self.finish_ui()
                    self.progress["value"] = self.progress["maximum"]
                    self.status_var.set("Completed.")
                    self.append_log("Done! Subtitles saved to: " + payload)
                    messagebox.showinfo("Completed",
                                        "Subtitles generated successfully.\n\n" + payload)
                elif kind == "error":
                    self.finish_ui()
                    self.status_var.set("Operation failed.")
                    self.append_log("ERROR: " + payload)
                    messagebox.showerror("Error", payload)
        except queue.Empty:
            pass
        self.root.after(100, self.poll_queue)

    def append_log(self, message):
        self.log_text.config(state="normal")
        self.log_text.insert("end", "> " + message + "\n")
        self.log_text.see("end")
        self.log_text.config(state="disabled")


def show_splash():
    """Show a short splash screen, then open the app."""
    splash = tk.Tk()
    splash.title("Whisper Subtitler")
    splash.resizable(False, False)
    splash.overrideredirect(True)
    splash.configure(bg=BG)

    frame = tk.Frame(splash, bg=BG, padx=50, pady=36)
    frame.pack()
    tk.Label(frame, text="Whisper Subtitler",
             font=(FONT_FAMILY, 22, "bold"), bg=BG, fg=FG).pack()
    tk.Label(frame, text="v" + APP_VERSION,
             font=(FONT_FAMILY, 11, "bold"), bg=BG, fg=GOLD).pack(pady=(0, 2))
    tk.Label(frame, text="Generate .srt subtitles from your videos",
             font=(FONT_FAMILY, 10), bg=BG, fg=MUTED).pack(pady=(2, 20))

    splash.update_idletasks()
    width = splash.winfo_reqwidth()
    height = splash.winfo_reqheight()
    x = (splash.winfo_screenwidth() - width) // 2
    y = (splash.winfo_screenheight() - height) // 2
    splash.geometry("+{}+{}".format(x, y))
    splash.after(2500, splash.destroy)
    splash.mainloop()


def main():
    show_splash()
    root = tk.Tk()
    app = SubtitlerApp(root)
    root.mainloop()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - never let a startup failure die silently
        import traceback
        _log = os.path.join(APP_DIR, "startup_error.log")
        try:
            with open(_log, "w", encoding="utf-8") as _f:
                _f.write(traceback.format_exc())
        except OSError:
            pass
        try:
            root = tk.Tk()
            root.withdraw()
            messagebox.showerror(
                "Whisper Subtitler - startup error",
                "The program could not start.\n\n"
                "{}\n\nDetails saved to:\n{}".format(exc, _log))
            root.destroy()
        except Exception:  # noqa: BLE001 - even tkinter itself failed
            pass
        raise
