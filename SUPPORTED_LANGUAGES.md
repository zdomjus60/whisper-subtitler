# Languages supported by Whisper Subtitler

List of the languages selectable in the GUI with their ISO codes.
The **Subtitle language** entry sets the **output** language of the
subtitles:

- the language spoken in the video is always detected automatically by Whisper;
- if the selected language matches the detected one, the subtitles are
  written directly without translation;
- if the selected language differs, the subtitles are **translated locally**
  (Argos Translate): the direct pair is used when available, otherwise the
  text is pivoted through English (e.g. `it → fr` = `it → en` + `en → fr`);
- the **Auto-detect** entry keeps the original language of the video
  (no translation).

Translation packages are downloaded **on first use**, only for the languages
actually used, and saved in the `translations/` folder of the application
(everything stays offline afterwards).

The automatic name of the generated subtitle file includes the **language
code** chosen (e.g. `video.it.srt` for Italian). With the *Auto-detect* entry
the code is the one of the language actually detected in the video
(e.g. `video.en.srt`).

| Subtitle language             | Code      |
|-------------------------------|-----------|
| Auto-detect                   | _(auto)_  |
| English                       | `en`      |
| Italiano                      | `it`      |
| Français                      | `fr`      |
| Español                       | `es`      |
| Deutsch                       | `de`      |
| Português                     | `pt`      |
| Nederlands                    | `nl`      |
| Polski                        | `pl`      |
| Русский (Russian)             | `ru`      |
| Türkçe (Turkish)              | `tr`      |
| Ελληνικά (Greek)              | `el`      |
| العربية (Arabic)              | `ar`      |
| Hindi                         | `hi`      |
| 中文 (Chinese)                | `zh`      |
| 日本語 (Japanese)             | `ja`      |
| 한국어 (Korean)               | `ko`      |