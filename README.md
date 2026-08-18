# transcribe-mlx

`transcribe-mlx.sh` batch-transcribes MP4 files locally on an Apple Silicon Mac
with [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper).
It produces readable text files with timestamps, shows live progress in a
terminal, caches raw results, and detects common Whisper repetition loops.

## Requirements

- macOS on Apple Silicon
- Bash
- Python 3.8 or newer
- `ffmpeg` and `ffprobe`
- `bc` and `shasum` (included with standard macOS installations)

For example, install FFmpeg with Homebrew:

```sh
brew install ffmpeg
```

## Quick start

```sh
chmod +x transcribe-mlx.sh
./transcribe-mlx.sh --install "/path/to/videos"
```

`--install` explicitly creates a private Python environment in the user cache
directory and installs the versioned `mlx-whisper` dependency. On first use,
the selected model may also download several gigabytes from Hugging Face.
Later runs do not need `--install`.

Without a directory argument, the script scans the current directory. Each
`example.mp4` produces `example.transcript.txt`. Raw model results are kept in
`.transcribe_cache/` so interrupted or repeated runs can avoid duplicate work.
Inputs must be regular files; symbolic links and special files are rejected.

## Options

```text
--install          Set up mlx-whisper if it is missing
--benchmark        Test up to three minutes of audio, then stop
--turbo            Use the faster large-v3-turbo model
--force            Re-transcribe even when the cache is current
--plain            Stream scrolling output instead of the live progress view
--model ID         Use another Hugging Face model ID or local model path
--language CODE    Set a language code; use auto for language detection
--prompt TEXT      Supply a short vocabulary or context hint
--no-prompt        Ignore a PROMPT inherited from the environment
--no-metadata      Omit source filename, model, duration, and date headers
--cache-dir PATH   Store cached JSON in another directory
--venv PATH        Use another Python environment
--help             Show the complete command help
```

The same settings are available as environment variables. For example:

```sh
LANGUAGE=es PROMPT="A clear conversation with technical terminology." \
  ./transcribe-mlx.sh "/path/to/videos"
```

Keep prompts short and sentence-like. Large lists of vocabulary can make
repetitive output more likely.

## Safe reruns and caching

Cache entries are tied to the video size and modification time, model,
language, prompt, and installed `mlx-whisper` version. A transcript is written
only after its candidate output passes the repetition check; a failed or
suspect rerun leaves any previous transcript unchanged. The script exits with a
nonzero status if a file fails or is flagged as suspect.

Cache directories are dedicated to this script and contain a marker file. A
custom `--cache-dir` must have an existing parent and must be either new, empty,
or already marked by the script. Do not point it at a video or project root.

Only one run may use a cache or output directory at a time. If the process is
forcibly killed, verify that no run is active before removing a leftover
`.transcribe-mlx-cache-lock` or `.transcribe-mlx-output-lock` directory.

## Privacy

Transcription runs on the Mac. Network access is used to install the Python
package and download model files when they are not already cached. Transcripts
and cached JSON contain the recognized speech and may therefore contain private
or identifying information. New transcripts and cache files are created with
user-only permissions.

By default, transcript headers also include the source filename, model, audio
duration, and transcription date. Use `--no-metadata` to omit that header.
Terminal output can include source filenames and short transcript previews, so
review logs before sharing them.

The included `.gitignore` excludes common media, transcripts, and caches, but
always review staged files before publishing a repository.

## Reproducibility and trust

The top-level `mlx-whisper` package is pinned, but its transitive dependencies
and Hugging Face model repository revisions are not hash-locked. For strict
reproducibility, use a separately locked Python environment and a reviewed local
model path. Treat `MLX_WHISPER_PACKAGE`, model, and path overrides as trusted
input.

## Scope

The script currently scans only `.mp4` and `.MP4` files and writes transcripts
beside the source videos. Repetition detection is a heuristic; review important
transcripts before relying on them.

## License

MIT. See `LICENSE`.
