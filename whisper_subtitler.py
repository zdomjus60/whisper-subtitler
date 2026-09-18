# Import the required libraries. Replaced `whisper` with `faster_whisper`
import time
import argparse
import re
from faster_whisper import WhisperModel
from datetime import timedelta
import subprocess
import os
# We do not need to import torch to check CUDA availability
# since we use a different logic.
# import torch

# This function is no longer needed: faster-whisper handles CUDA checks
# differently and does not rely on this logic. Device handling is implicit
# or specified when creating the model.
# def check_cuda_availability():
#     print("Checking CUDA availability...")
#     if torch.cuda.is_available():
#         print("CUDA is available. Using the GPU.")
#         device = "cuda"
#     else:
#         print("CUDA is not available. Using the CPU.")
#         device = "cpu"
#     return device

def extract_audio(video_path, audio_path):
    print("Starting audio extraction...")
    command = [
        'ffmpeg',
        '-i',
        video_path,
        '-q:a',
        '0',
        '-map',
        'a',
        audio_path
    ]
    subprocess.run(command, check=True)
    print(f"Audio extraction completed. Audio file saved to: {audio_path}")

def get_audio_duration(audio_path):
    """Return the media duration in seconds, or *None* on failure."""
    try:
        result = subprocess.run(["ffmpeg", "-i", audio_path],
                                capture_output=True, text=True)
        match = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)",
                          result.stderr or "")
        if not match:
            return None
        h, m, s = (float(g) for g in match.groups())
        return h * 3600 + m * 60 + s
    except Exception:
        return None


def format_timestamp(seconds):
    """Formats seconds into SRT timestamp format (HH:MM:SS,ms)."""
    td = timedelta(seconds=seconds)
    total_seconds = int(td.total_seconds())
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    milliseconds = td.microseconds // 1000
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{milliseconds:03d}"

def transcribe_audio(audio_path, language='en', model_name='small'):
    print("Starting audio transcription with word-level timestamps...")
    try:
        # --- KEY CHANGE FOR FASTER-WHISPER ---
        # Replace the OpenAI Whisper model loading with faster-whisper.
        # We use device="cpu" and compute_type="int8" to take advantage
        # of the Intel optimizations.
        model = WhisperModel(model_name, device="cpu", compute_type="int8")
        
        print("Faster-whisper model loaded and optimized.")
        
        # faster-whisper does not need `options` and `transcribe_options`
        # like this. The API is simpler.
        # word_timestamps is enabled via an option in the transcribe method.
        segments, info = model.transcribe(audio_path, language=language, beam_size=5, word_timestamps=True)
        
        print("Transcription completed with word-level timestamps.")
        
        # faster-whisper returns a generator, which is exactly what we need.
        # We return it directly.
        return segments
    except Exception as e:
        print(f"Error during transcription: {e}")
        return []

def _is_wide_char(ch):
    """True for CJK / fullwidth characters that render ~2 columns wide."""
    cp = ord(ch)
    if 0x1100 <= cp <= 0x11FF:
        return True
    if 0x2E80 <= cp <= 0x303F:
        return True
    if 0x3040 <= cp <= 0x30FF:
        return True
    if 0x3400 <= cp <= 0x4DBF:
        return True
    if 0x4E00 <= cp <= 0x9FFF:
        return True
    if 0xA960 <= cp <= 0xA97F:
        return True
    if 0xAC00 <= cp <= 0xD7A3:
        return True
    if 0xF900 <= cp <= 0xFAFF:
        return True
    if 0xFE30 <= cp <= 0xFE4F:
        return True
    if 0xFF00 <= cp <= 0xFFEF:
        return True
    return False


def _char_width(ch):
    return 2 if _is_wide_char(ch) else 1


def build_line(parts):
    """Join word tokens into a subtitle line, keeping CJK characters together."""
    out = parts[0]
    for part in parts[1:]:
        prev_ch = out[-1]
        cur_ch = part[0]
        if _is_wide_char(prev_ch) and _is_wide_char(cur_ch):
            out += part
        else:
            out += " " + part
    return out


def write_srt(segments, srt_path, max_width=42, duration=None):
    print("Writing SRT file with word-level timestamps...")
    
    # faster-whisper returns segments in a slightly different way.
    # The output is a generator, so your `for` loop will work,
    # but the internal segment structure is different.
    # We adapt the writing logic to the new structure.
    with open(srt_path, 'w', encoding='utf-8') as srt_file:
        segment_idx = 1
        
        # `segments` is a generator, so we iterate over it
        for segment in segments:
            if duration:
                frac = min(segment.end / duration, 1.0)
                print(f"\rTranscribing... {frac*100:3.0f}%", end="", flush=True)
            # faster-whisper segments have a `words` attribute directly
            if not segment.words:
                continue

            # Lines are sized by display width (CJK characters count as two
            # columns) so that space-less scripts are readable too.
            line_parts = []
            line_start = None
            line_end = None
            line_width = 0

            # Here we iterate over the `Word` objects of faster-whisper
            for i, word_info in enumerate(segment.words):
                word_text = word_info.word.strip()
                if not word_text:
                    continue

                if line_start is None:
                    line_start = word_info.start

                sep_cost = 0
                if line_parts:
                    prev_ch = line_parts[-1][-1]
                    cur_ch = word_text[0]
                    sep_cost = 0 if (_is_wide_char(prev_ch) and _is_wide_char(cur_ch)) else 1
                word_width = sum(_char_width(c) for c in word_text)

                if line_parts and line_width + sep_cost + word_width > max_width:
                    srt_file.write(f"{segment_idx}\n")
                    srt_file.write(f"{format_timestamp(line_start)} --> {format_timestamp(line_end)}\n")
                    srt_file.write(f"{build_line(line_parts)}\n\n")
                    segment_idx += 1
                    line_parts = []
                    line_start = word_info.start
                    line_width = 0
                    sep_cost = 0

                line_parts.append(word_text)
                line_width += sep_cost + word_width
                line_end = word_info.end

                # The rest of the line-writing logic stays the same
                if i == len(segment.words) - 1:
                    srt_file.write(f"{segment_idx}\n")
                    srt_file.write(f"{format_timestamp(line_start)} --> {format_timestamp(line_end)}\n")
                    srt_file.write(f"{build_line(line_parts)}\n\n")
                    segment_idx += 1
                    line_parts = []
                    line_start = None
                    line_end = None
                    line_width = 0

    if duration:
        print()
    print(f"SRT file written to {srt_path}.")

def main(video_path, srt_path, language='en', model_name='small', audio_path='audio.mp3'):
    extract_audio(video_path, audio_path)
    duration = get_audio_duration(audio_path)
    segments = transcribe_audio(audio_path, language=language, model_name=model_name)
    if segments:
        write_srt(segments, srt_path, duration=duration)
    else:
        print("No text segments found. Check the audio or the transcription parameters.")
    os.remove(audio_path)
    print("Cleanup completed.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Transcribe audio from video and generate SRT subtitles.")
    parser.add_argument("video_path", type=str, help="Path to the input video file.")
    parser.add_argument("srt_path", type=str, help="Path to the output SRT subtitle file.")
    parser.add_argument("--language", type=str, default="en", help="Language of the audio (e.g., 'en', 'it', 'fr'). Default is 'en'.")
    parser.add_argument("--model", type=str, default="small", help="Whisper model to use (e.g., 'tiny', 'base', 'small', 'medium', 'large'). Default is 'small'.")

    args = parser.parse_args()

    print("--- Starting the transcription process ---")
    start_time = time.time()  # <--- Record the start time

    main(args.video_path, args.srt_path, args.language, args.model)
    end_time = time.time()    # <--- Record the end time
    duration = end_time - start_time
    print(f"--- Process completed in {duration:.2f} seconds ---")