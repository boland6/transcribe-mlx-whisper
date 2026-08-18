#!/usr/bin/env bash
# Batch-transcribe MP4 files locally on Apple Silicon using mlx-whisper.
#
# Usage:
#   ./transcribe-mlx.sh [options] [directory]
#
# Run with --help for configuration details. Finished files are cached, and a
# rerun is safe: existing transcripts are replaced only after new output passes
# the repetition check.

set -uo pipefail
umask 077

SCRIPT_NAME="$(basename "$0")"
FORCE="${FORCE:-0}"
BENCH="${BENCH:-0}"
TURBO="${TURBO:-0}"
PLAIN="${PLAIN:-0}"
INSTALL="${INSTALL:-0}"
METADATA="${METADATA:-1}"
MODEL="${MODEL:-}"
LANGUAGE="${LANGUAGE:-en}"
# An empty prompt is intentional. Long, list-shaped prompts can increase
# repetitive output; when supplying one, keep it short and natural.
PROMPT="${PROMPT-}"
INPUT_DIR="${INPUT_DIR:-.}"
CACHE_DIR="${CACHE_DIR:-}"
VENV="${VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/transcribe-mlx/venv}"
# This is the version used to validate this release. Override the full package
# spec when deliberately testing a newer version.
MLX_WHISPER_PACKAGE="${MLX_WHISPER_PACKAGE:-mlx-whisper==0.4.3}"
TRANSCRIBE_CACHE_VERSION=2

if [ -t 1 ] && [ "${NO_COLOR+x}" != "x" ]; then
  C_BOLD='\033[1m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_ERROR='\033[31m'; C_RESET='\033[0m'
else
  C_BOLD=''; C_OK=''; C_WARN=''; C_ERROR=''; C_RESET=''
fi

bold() { printf '%b%s%b\n' "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '%b  ! %s%b\n' "$C_WARN" "$*" "$C_RESET"; }
die()  { printf '%b\nERROR: %s%b\n\n' "$C_ERROR" "$*" "$C_RESET" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options] [directory]

Transcribe every .mp4 file in directory (the current directory by default).
Transcripts are written beside the videos as <name>.transcript.txt.

Options:
  --install          Create the private Python environment if it is missing
  --benchmark        Time up to three minutes of audio, then stop
  --turbo            Use the faster large-v3-turbo model
  --force            Re-transcribe files even when the cache is current
  --plain            Stream raw mlx-whisper output instead of a progress view
  --model ID         Override the Hugging Face model ID or local model path
  --language CODE    Language code (default: en); use auto for detection
  --prompt TEXT      Short vocabulary/context hint (default: none)
  --no-prompt        Explicitly disable a PROMPT inherited from the environment
  --no-metadata      Omit filename, model, duration, and date from text headers
  --cache-dir PATH   Dedicated cache directory (default: <directory>/.transcribe_cache)
  --venv PATH        Python environment (default: user cache directory)
  -h, --help         Show this help

The matching environment variables are also supported: INSTALL, BENCH, TURBO,
FORCE, PLAIN, MODEL, LANGUAGE, PROMPT, METADATA, INPUT_DIR, CACHE_DIR, VENV, and
MLX_WHISPER_PACKAGE. Boolean values use 0 or 1.

First use downloads Python packages with --install and may download several GB
of model data from Hugging Face when transcription begins.
EOF
}

need_value() {
  [ "$#" -ge 2 ] || die "$1 requires a value."
}

input_arg_seen=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --benchmark) BENCH=1; shift ;;
    --turbo) TURBO=1; shift ;;
    --force) FORCE=1; shift ;;
    --plain) PLAIN=1; shift ;;
    --model) need_value "$@"; MODEL="$2"; shift 2 ;;
    --language) need_value "$@"; LANGUAGE="$2"; shift 2 ;;
    --prompt) need_value "$@"; PROMPT="$2"; shift 2 ;;
    --no-prompt) PROMPT=""; shift ;;
    --no-metadata) METADATA=0; shift ;;
    --cache-dir) need_value "$@"; CACHE_DIR="$2"; shift 2 ;;
    --venv) need_value "$@"; VENV="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1" ;;
    *)
      [ "$input_arg_seen" = "0" ] || die "Only one input directory may be supplied."
      INPUT_DIR="$1"; input_arg_seen=1; shift
      ;;
  esac
done

if [ "$#" -gt 0 ]; then
  [ "$#" -eq 1 ] && [ "$input_arg_seen" = "0" ] \
    || die "Only one input directory may be supplied."
  INPUT_DIR="$1"
fi

for flag in "$FORCE" "$BENCH" "$TURBO" "$PLAIN" "$INSTALL" "$METADATA"; do
  case "$flag" in 0|1) ;; *) die "Boolean options and environment variables must be 0 or 1." ;; esac
done

if [ -z "$MODEL" ]; then
  if [ "$TURBO" = "1" ]; then
    MODEL="mlx-community/whisper-large-v3-turbo"
  else
    MODEL="mlx-community/whisper-large-v3-mlx"
  fi
fi

[ -d "$INPUT_DIR" ] || die "Input directory not found: $INPUT_DIR"
DIR="$(cd "$INPUT_DIR" && pwd -P)" || die "Could not open input directory: $INPUT_DIR"
CACHE="${CACHE_DIR:-$DIR/.transcribe_cache}"
case "$CACHE" in /*) ;; *) CACHE="$(pwd -P)/$CACHE" ;; esac
case "$VENV" in /*) ;; *) VENV="$(pwd -P)/$VENV" ;; esac

# Redrawing progress does not belong in redirected output or NO_COLOR mode.
if [ ! -t 1 ] || [ "${NO_COLOR+x}" = "x" ]; then
  PLAIN=1
fi

WORK=""
LOCK_DIR=""
LOCK_TOKEN=""
OUTPUT_LOCK_DIR=""
OUTPUT_LOCK_TOKEN=""
INSTALL_LOCK_DIR=""
INSTALL_LOCK_TOKEN=""
OUTPUT_STAGE=""
ACTIVE_TXT_TMP=""
ACTIVE_JSON_TMP=""
ACTIVE_META_TMP=""

release_owned_lock() {
  local lock_dir="$1" lock_token="$2" lock_owner=""
  [ -n "$lock_dir" ] && [ -d "$lock_dir" ] || return 0
  if [ -f "$lock_dir/pid" ] && [ ! -L "$lock_dir/pid" ]; then
    IFS= read -r lock_owner 2>/dev/null < "$lock_dir/pid" || lock_owner=""
  fi
  if [ -n "$lock_token" ] && [ "$lock_owner" = "$lock_token" ]; then
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}

cleanup() {
  [ -z "$ACTIVE_TXT_TMP" ] || rm -f "$ACTIVE_TXT_TMP"
  [ -z "$ACTIVE_JSON_TMP" ] || rm -f "$ACTIVE_JSON_TMP"
  [ -z "$ACTIVE_META_TMP" ] || rm -f "$ACTIVE_META_TMP"
  if [ -n "$OUTPUT_STAGE" ] && [ -d "$OUTPUT_STAGE" ]; then
    rm -rf "$OUTPUT_STAGE"
  fi
  release_owned_lock "$OUTPUT_LOCK_DIR" "$OUTPUT_LOCK_TOKEN"
  release_owned_lock "$LOCK_DIR" "$LOCK_TOKEN"
  release_owned_lock "$INSTALL_LOCK_DIR" "$INSTALL_LOCK_TOKEN"
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
  [ -t 1 ] && printf '\033[?25h' || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export TOKENIZERS_PARALLELISM=false

hms() {
  local s=${1%.*}
  printf '%d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

safe_text() {
  printf '%s' "$*" | LC_ALL=C tr -d '[:cntrl:]'
}

probe_duration() {
  local value
  value="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null)" \
    || return 1
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  [[ ! "$value" =~ ^0+([.]0+)?$ ]] || return 1
  printf '%s\n' "$value"
}

cache_signature() {
  local source_stats
  source_stats="$(stat -f '%z:%m' "$1" 2>/dev/null)" || return 1
  {
    printf '%s\0' "$source_stats" "$MODEL" "$LANGUAGE" "$PROMPT" \
      "$MLX_VERSION" "$TRANSCRIBE_CACHE_VERSION"
  } | shasum -a 256 | awk '{print $1}'
}

shopt -s nullglob
FILES=("$DIR"/*.mp4 "$DIR"/*.MP4)
[ ${#FILES[@]} -gt 0 ] || die "No .mp4 files found in $DIR"

# ---------------------------------------------------------------- preflight --
bold "=== Preflight ==="

[ "$(uname -s)" = "Darwin" ] || die "This script is for macOS."
[ "$(uname -m)" = "arm64" ] || die "mlx-whisper requires Apple Silicon."

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found. Install with: brew install ffmpeg"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found. It is normally installed with ffmpeg."
command -v python3 >/dev/null 2>&1 || die "python3 not found. Install Python 3 and try again."
command -v bc >/dev/null 2>&1 || die "bc not found. Install it and try again."
command -v shasum >/dev/null 2>&1 || die "shasum not found. Install it and try again."

[ ! -L "$VENV" ] || die "Refusing to use a symlink as the virtual environment: $VENV"
[ ! -e "$VENV" ] || [ -d "$VENV" ] || die "Virtual environment path is not a directory: $VENV"
[ ! -d "$VENV.install-lock" ] || die "Another setup may be using $VENV. If not, remove: $VENV.install-lock"
if [ ! -x "$VENV/bin/mlx_whisper" ]; then
  [ "$INSTALL" = "1" ] || die "mlx-whisper is not installed in $VENV. Re-run with --install."
  bold ""
  bold "=== First-time setup ==="
  info "Creating an isolated Python environment at $VENV"
  info "Installing: $MLX_WHISPER_PACKAGE"
  echo
  mkdir -p "$(dirname "$VENV")" || die "Could not create the virtual environment parent directory."
  INSTALL_LOCK_DIR="$VENV.install-lock"
  if ! mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
    die "Another setup may be using $VENV. If not, remove: $INSTALL_LOCK_DIR"
  fi
  INSTALL_LOCK_TOKEN="$$"
  if ! printf '%s\n' "$INSTALL_LOCK_TOKEN" > "$INSTALL_LOCK_DIR/pid"; then
    rm -f "$INSTALL_LOCK_DIR/pid"
    rmdir "$INSTALL_LOCK_DIR" 2>/dev/null || true
    INSTALL_LOCK_DIR=""; INSTALL_LOCK_TOKEN=""
    die "Could not initialize the setup lock."
  fi
  python3 -m venv "$VENV" || die "Could not create the virtual environment."
  "$VENV/bin/python" -m pip install "$MLX_WHISPER_PACKAGE" \
    || die "Install failed. Remove the incomplete environment and re-run with --install."
  "$VENV/bin/python" -c 'import importlib.metadata as m; print(m.version("mlx-whisper"))' >/dev/null \
    || die "The installed mlx-whisper package could not be verified."
  release_owned_lock "$INSTALL_LOCK_DIR" "$INSTALL_LOCK_TOKEN"
  INSTALL_LOCK_DIR=""; INSTALL_LOCK_TOKEN=""
  echo
fi
MLX="$VENV/bin/mlx_whisper"
PY="$VENV/bin/python"
"$PY" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' \
  || die "The Python environment must use Python 3.8 or newer."
MLX_VERSION="$("$PY" -c 'import importlib.metadata as m; print(m.version("mlx-whisper"))')" \
  || die "The Python environment does not contain a readable mlx-whisper installation."
info "mlx_whisper: $MLX"
info "mlx-whisper version: $(safe_text "$MLX_VERSION")"
info "model: $(safe_text "$MODEL")"
info "language: $(safe_text "$LANGUAGE")"

CACHE_CREATED=0
if [ -e "$CACHE" ] || [ -L "$CACHE" ]; then
  [ ! -L "$CACHE" ] || die "Refusing to use a symlink as the cache directory: $CACHE"
  [ -d "$CACHE" ] || die "Cache path is not a directory: $CACHE"
else
  [ -d "$(dirname "$CACHE")" ] \
    || die "The parent of --cache-dir must already exist: $(dirname "$CACHE")"
  mkdir "$CACHE" || die "Could not create cache directory: $CACHE"
  CACHE_CREATED=1
fi

CACHE_ID="$(stat -f '%d:%i' "$CACHE" 2>/dev/null)" || die "Could not inspect cache directory: $CACHE"
CACHE="$(cd "$CACHE" && pwd -P)" || die "Could not open cache directory: $CACHE"
[ "$(stat -f '%d:%i' "$CACHE" 2>/dev/null)" = "$CACHE_ID" ] \
  || die "Cache directory changed while it was being opened."
[ "$(stat -f '%u' "$CACHE" 2>/dev/null)" = "$(id -u)" ] \
  || die "The cache directory must be owned by the current user: $CACHE"

CACHE_MARKER="$CACHE/.transcribe-mlx-cache"
if [ "$CACHE_CREATED" = "1" ]; then
  chmod 700 "$CACHE" || die "Could not restrict cache permissions: $CACHE"
  printf '%s\n' 'transcribe-mlx cache v1' > "$CACHE_MARKER" \
    || die "Could not initialize cache directory: $CACHE"
elif [ ! -e "$CACHE_MARKER" ] && [ ! -L "$CACHE_MARKER" ]; then
  CACHE_FIRST_ENTRY="$(find "$CACHE" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
  [ -z "$CACHE_FIRST_ENTRY" ] \
    || die "Refusing to use an unrecognized, nonempty cache directory: $CACHE"
  chmod 700 "$CACHE" || die "Could not restrict cache permissions: $CACHE"
  printf '%s\n' 'transcribe-mlx cache v1' > "$CACHE_MARKER" \
    || die "Could not initialize cache directory: $CACHE"
else
  [ -f "$CACHE_MARKER" ] && [ ! -L "$CACHE_MARKER" ] \
    || die "Cache marker is not a regular file: $CACHE_MARKER"
  IFS= read -r CACHE_MARKER_VALUE < "$CACHE_MARKER" || CACHE_MARKER_VALUE=""
  [ "$CACHE_MARKER_VALUE" = 'transcribe-mlx cache v1' ] \
    || die "Cache marker is not recognized: $CACHE_MARKER"
  chmod 700 "$CACHE" || die "Could not restrict cache permissions: $CACHE"
fi
chmod 600 "$CACHE_MARKER" || die "Could not restrict cache marker permissions."

LOCK_DIR="$CACHE/.transcribe-mlx-cache-lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "Another run may be using this cache. If not, remove: $LOCK_DIR"
fi
LOCK_TOKEN="$$"
if ! printf '%s\n' "$LOCK_TOKEN" > "$LOCK_DIR/pid"; then
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCK_DIR=""; LOCK_TOKEN=""
  die "Could not initialize the cache lock."
fi

OUTPUT_LOCK_DIR="$DIR/.transcribe-mlx-output-lock"
if ! mkdir "$OUTPUT_LOCK_DIR" 2>/dev/null; then
  die "Another run may be writing transcripts here. If not, remove: $OUTPUT_LOCK_DIR"
fi
OUTPUT_LOCK_TOKEN="$$"
if ! printf '%s\n' "$OUTPUT_LOCK_TOKEN" > "$OUTPUT_LOCK_DIR/pid"; then
  rm -f "$OUTPUT_LOCK_DIR/pid"
  rmdir "$OUTPUT_LOCK_DIR" 2>/dev/null || true
  OUTPUT_LOCK_DIR=""; OUTPUT_LOCK_TOKEN=""
  die "Could not initialize the output lock."
fi

WORK="$(mktemp -d)" || die "Could not create a temporary work directory."
[ -n "$WORK" ] && [ -d "$WORK" ] || die "Could not create a temporary work directory."

# ------------------------------------------------------- live progress view --
cat > "$WORK/progress.py" <<'PYEOF'
"""Turns mlx-whisper's segment output into a live progress display.

Reads lines like  [04:31.000 --> 04:38.240]  some transcribed text
(note: the hours field is omitted for the first hour, present after it)
and renders a redrawing status block with per-file and overall ETAs.
"""
import sys, re, time, shutil

file_dur   = float(sys.argv[1])   # length of the current audio file, seconds
idx        = int(sys.argv[2])     # 1-based position in the to-do list
n_files    = int(sys.argv[3])     # how many files this run will transcribe
prior_done = float(sys.argv[4])   # audio seconds finished earlier in this run
total_todo = float(sys.argv[5])   # audio seconds this run must get through
name       = sys.argv[6]

TS = r"(?:\d+:)?\d+:\d+\.\d+"
SEGMENT = re.compile(r"^\[(" + TS + r") --> (" + TS + r")\]\s*(.*)$")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")

def clean_terminal_text(value):
    return CONTROL.sub(" ", value)

name = clean_terminal_text(name)

def parse_ts(t):
    parts = t.split(":")
    sec = float(parts[-1])
    if len(parts) > 1:
        sec += int(parts[-2]) * 60
    if len(parts) > 2:
        sec += int(parts[-3]) * 3600
    return sec

def clock(s):
    s = max(0, int(s))
    if s >= 3600:
        return "%d:%02d:%02d" % (s // 3600, (s % 3600) // 60, s % 60)
    return "%d:%02d" % (s // 60, s % 60)

BLOCK = 5
started = time.time()
drawn = False
pos = 0.0
preview = ""

def draw(final=False):
    global drawn
    width = shutil.get_terminal_size((100, 24)).columns
    elapsed = max(time.time() - started, 0.001)
    frac = min(pos / file_dur, 1.0) if file_dur > 0 else 0.0
    speed = pos / elapsed
    left_file = (file_dur - pos) / speed if speed > 0 else 0
    run_done = prior_done + pos
    left_all = (total_todo - run_done) / speed if speed > 0 else 0
    all_frac = min(run_done / total_todo, 1.0) if total_todo > 0 else 0.0

    barw = max(16, min(38, width - 46))
    filled = int(round(barw * frac))
    bar = "\033[36m" + "█" * filled + "\033[90m" + "░" * (barw - filled) + "\033[0m"

    title = name if len(name) <= width - 4 else name[: width - 7] + "..."
    lines = [
        "  \033[1m%s\033[0m" % title,
        "  %s  \033[1m%3d%%\033[0m   %s / %s" % (bar, round(frac * 100), clock(pos), clock(file_dur)),
        "  \033[90mspeed\033[0m %.1fx   \033[90melapsed\033[0m %s   \033[90mleft\033[0m ~%s"
            % (speed, clock(elapsed), clock(left_file)),
        "  \033[90mfile\033[0m %d/%d   \033[90moverall\033[0m %d%% of %s audio   \033[90mall done in\033[0m ~%s"
            % (idx, n_files, round(all_frac * 100), clock(total_todo), clock(left_all)),
    ]

    tail = ("  ▸ " + preview) if preview else "  ▸"
    if len(tail) > width - 2:
        tail = tail[: width - 5] + "..."
    lines.append("\033[90m%s\033[0m" % tail)

    out = []
    if drawn:
        out.append("\033[%dA" % BLOCK)
    for ln in lines:
        out.append("\033[2K" + ln + "\n")
    sys.stdout.write("".join(out))
    sys.stdout.flush()
    drawn = True

sys.stdout.write("\033[?25l")          # hide cursor while the block redraws
try:
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.rstrip("\n")
        m = SEGMENT.match(line)
        if m:
            pos = parse_ts(m.group(2))
            text = m.group(3).strip()
            if text:
                preview = clean_terminal_text(text)
            draw()
        elif line.strip():
            clean_line = clean_terminal_text(line)
            if not drawn:
                print(clean_line)
            else:
                print(clean_line, file=sys.stderr)

    # Snap to a clean 100% only if we genuinely reached the end. If the stream
    # stopped early (mlx crashed), leave the bar where it died rather than
    # claiming the file finished.
    if drawn:
        if file_dur > 0 and pos >= 0.95 * file_dur:
            pos = file_dur
        draw(final=True)
finally:
    sys.stdout.write("\033[?25h")      # restore cursor
    sys.stdout.flush()
PYEOF

# Strip terminal control characters from the scrolling view while preserving
# normal text, tabs, and newlines.
cat > "$WORK/plain.py" <<'PYEOF'
import re
import sys

CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
for line in sys.stdin:
    sys.stdout.write(CONTROL.sub("", line))
    sys.stdout.flush()
PYEOF

cat > "$WORK/has_text.py" <<'PYEOF'
import os
import re
import stat
import sys

path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
fd = os.open(path, flags)
if not stat.S_ISREG(os.fstat(fd).st_mode):
    os.close(fd)
    raise OSError("transcript is not a regular file")
with os.fdopen(fd, encoding="utf8") as source:
    body = source.read()

lines = body.splitlines()
if (len(lines) >= 3 and lines[1] and set(lines[1]) == {"-"}
        and lines[2].startswith("Duration: ")):
    body = "\n".join(lines[3:])
body = re.sub(r"^\[\d\d:\d\d:\d\d\]$", "", body, flags=re.M)
raise SystemExit(0 if body.split() else 1)
PYEOF

# ------------------------------------------------------------ quality check --
# Whisper can fall into a repetition loop and emit the same short phrase for
# tens of minutes. This detects that so a corrupt transcript is re-queued
# instead of silently shipping. Prints "OK <pct>" or "SUSPECT <pct>".
cat > "$WORK/qc.py" <<'PYEOF'
"""qc.py <transcript.txt> [segments.json] -> "OK <pct>" | "SUSPECT <pct>"

<pct> is the share of the transcript taken up by its most repeated unit. The
thresholds are intentionally conservative heuristics, not a correctness test.
"""
import sys, os, re, json, collections

txt_path = sys.argv[1]
json_path = sys.argv[2] if len(sys.argv) > 2 else ""

def verdict(pct, suspect):
    print("%s %d" % ("SUSPECT" if suspect else "OK", pct))
    sys.exit(1 if suspect else 0)

# --- preferred: segment-level repetition from the JSON ---
if json_path and os.path.exists(json_path):
    try:
        with open(json_path, encoding="utf8") as source:
            payload = json.load(source)
        segs = (payload.get("segments") or []) if isinstance(payload, dict) else []
        texts = [s.get("text", "").strip() for s in segs if isinstance(s, dict)]
        texts = [text for text in texts if text]
        if len(texts) >= 20:
            counts = collections.Counter(texts)
            dominant = 100 * counts.most_common(1)[0][1] / len(texts)
            unique = 100 * len(counts) / len(texts)
            verdict(round(dominant), dominant >= 30 or unique <= 20)
    except (ValueError, OSError, TypeError, AttributeError):
        pass

# --- fallback: token repetition in the text ---
try:
    body = open(txt_path, encoding="utf8").read()
except OSError:
    verdict(100, True)

lines = body.splitlines()
if (len(lines) >= 3 and lines[1] and set(lines[1]) == {"-"}
        and lines[2].startswith("Duration: ")):
    body = "\n".join(lines[3:])
body = re.sub(r"^\[\d\d:\d\d:\d\d\]$", "", body, flags=re.M)
tokens = body.split()
if len(tokens) < 50:
    # A short or silent recording is not evidence of a repetition loop.
    verdict(0, False)

counts = collections.Counter(tokens)
dominant = 100 * counts.most_common(1)[0][1] / len(tokens)
unique = 100 * len(counts) / len(tokens)
verdict(round(dominant), dominant >= 35 or unique <= 5)
PYEOF

# --------------------------------------------------- JSON -> timestamped txt --
# Understands both mlx-whisper output ("segments") and insanely-fast-whisper
# output ("chunks"), so transcripts from either script come out identical.
cat > "$WORK/to_txt.py" <<'PYEOF'
import json, os, sys, textwrap, datetime

json_path, txt_path, source_name, duration_s, model, include_metadata = sys.argv[1:7]

with open(json_path, encoding="utf8") as f:
    data = json.load(f)

def ts(sec):
    sec = int(sec or 0)
    return "%02d:%02d:%02d" % (sec // 3600, (sec % 3600) // 60, sec % 60)

items, last_end = [], 0.0

if data.get("segments"):                      # mlx-whisper
    for s in data["segments"]:
        start = s.get("start")
        end = s.get("end")
        start = last_end if start is None else start
        end = start if end is None else end
        text = (s.get("text") or "").strip()
        if text:
            items.append((start, end, text))
            last_end = end
elif data.get("chunks"):                      # insanely-fast-whisper
    for ch in data["chunks"]:
        stamp = ch.get("timestamp") or [None, None]
        start = stamp[0] if stamp[0] is not None else last_end
        end = stamp[1] if len(stamp) > 1 and stamp[1] is not None else start
        text = (ch.get("text") or "").strip()
        if text:
            items.append((start, end, text))
            last_end = end

PARA_SECONDS = 30.0
PARA_CHARS = 500

paragraphs, cur, cur_start = [], [], None
for start, end, text in items:
    if cur_start is None:
        cur_start = start
    cur.append(text)
    if (end - cur_start) >= PARA_SECONDS or len(" ".join(cur)) >= PARA_CHARS:
        paragraphs.append((cur_start, " ".join(cur)))
        cur, cur_start = [], None
if cur:
    paragraphs.append((cur_start or 0.0, " ".join(cur)))

if not paragraphs and data.get("text"):
    paragraphs = [(0.0, data["text"].strip())]

header = []
if include_metadata == "1":
    mins = float(duration_s) / 60.0
    header = [
        source_name,
        "-" * min(len(source_name), 100),
        "Duration: %.0f min   |   Model: %s   |   Transcribed: %s"
            % (mins, model, datetime.date.today().isoformat()),
        "",
        "",
    ]

body = []
for start, text in paragraphs:
    body.append("[%s]" % ts(start))
    body.append(textwrap.fill(text, width=100))
    body.append("")

flags = os.O_WRONLY | os.O_TRUNC
flags |= getattr(os, "O_NOFOLLOW", 0)
fd = os.open(txt_path, flags)
with os.fdopen(fd, "w", encoding="utf8") as f:
    f.write("\n".join(header + body).rstrip() + "\n")

words = sum(len(t.split()) for _, t in paragraphs)
print("%d paragraphs, %d words" % (len(paragraphs), words))
PYEOF

# PROG_* are set by the loop just before each call.
PROG_DUR=0; PROG_IDX=1; PROG_N=1; PROG_PRIOR=0; PROG_TOTAL=1; PROG_NAME=""

run_mlx() {
  local wav="$1" out="$2" stem
  local -a args
  stem="$(basename "${wav%.*}")"

  args=(
    "$wav"
    --model "$MODEL"
    --task transcribe
    --condition-on-previous-text False
    --output-dir "$WORK/out"
    --output-format json
    --output-name "$stem"
    --verbose True
  )
  if [ -n "$LANGUAGE" ] && [ "$LANGUAGE" != "auto" ]; then
    args+=(--language "$LANGUAGE")
  fi
  if [ -n "$PROMPT" ]; then
    args+=(--initial-prompt "$PROMPT")
  fi

  # PYTHONUNBUFFERED is essential: without it Python block-buffers stdout when
  # piped, and the progress display would sit frozen then jump.
  if [ "$BENCH" = "1" ]; then
    PYTHONUNBUFFERED=1 "$MLX" "${args[@]}" || return 1
  elif [ "$PLAIN" = "1" ]; then
    PYTHONUNBUFFERED=1 "$MLX" "${args[@]}" \
      | "$PY" "$WORK/plain.py" \
      || return 1
  else
    PYTHONUNBUFFERED=1 "$MLX" "${args[@]}" \
      | "$PY" "$WORK/progress.py" \
            "$PROG_DUR" "$PROG_IDX" "$PROG_N" "$PROG_PRIOR" "$PROG_TOTAL" "$PROG_NAME" \
      || return 1
  fi
  [ -s "$WORK/out/$stem.json" ] || return 1
  mv "$WORK/out/$stem.json" "$out"
}

# Output and cache names are based on the video stem, so collisions would make
# the result ambiguous. Control characters are also rejected before display.
SEEN_STEMS=()
for VIDEO in "${FILES[@]}"; do
  BASE="$(basename "$VIDEO")"
  STEM="${BASE%.*}"
  [ -n "$STEM" ] || die "A video must have a non-empty name before .mp4."
  [ "$BASE" = "$(safe_text "$BASE")" ] \
    || die "Video filenames may not contain terminal control characters."
  [ -f "$VIDEO" ] && [ ! -L "$VIDEO" ] \
    || die "Video inputs must be regular files, not links or special files: $(safe_text "$BASE")"
  for SEEN in "${SEEN_STEMS[@]:-}"; do
    [ -z "$SEEN" ] || [ "$SEEN" != "$STEM" ] \
      || die "Two videos have the same output name: $STEM"
  done
  SEEN_STEMS+=("$STEM")
done

# ------------------------------------------------------------- benchmark ----
if [ "$BENCH" = "1" ]; then
  bold ""
  bold "=== Benchmark: up to 3 minutes of audio ==="
  BVIDEO="${FILES[0]}"
  info "sample: $(safe_text "$(basename "$BVIDEO")")"
  ffmpeg -nostdin -v error -y -t 180 -i "$BVIDEO" -vn -ac 1 -ar 16000 \
         -c:a pcm_s16le "$WORK/bench.wav" || die "Could not extract the sample."
  BENCH_DUR="$(probe_duration "$WORK/bench.wav")" \
    || die "Could not determine the benchmark sample duration."
  mkdir -p "$WORK/out" || die "Could not create the benchmark output directory."

  ffmpeg -nostdin -v error -y -t 10 -i "$WORK/bench.wav" "$WORK/warm.wav" \
    || die "Could not create the warm-up sample."
  info "warming the model cache (the first run may download several GB)"
  run_mlx "$WORK/warm.wav" "$WORK/warm.json" >/dev/null 2>&1 \
    || die "Model warm-up failed. Run without --benchmark to see the full error."

  bold ""
  info "timing $(hms "$BENCH_DUR") of audio..."
  B_START=$(date +%s)
  run_mlx "$WORK/bench.wav" "$WORK/bench.json" >/dev/null 2>&1 \
    || die "Benchmark failed. Run without --benchmark to see the full error."
  B_ELAPSED=$(( $(date +%s) - B_START ))
  [ "$B_ELAPSED" -lt 1 ] && B_ELAPSED=1

  TOTAL_AUDIO=0
  for f in "${FILES[@]}"; do
    d="$(probe_duration "$f")" || die "Could not read the duration of: $(safe_text "$(basename "$f")")"
    TOTAL_AUDIO=$(echo "$TOTAL_AUDIO + $d" | bc -l)
  done
  RTF=$(echo "$BENCH_DUR / $B_ELAPSED" | bc -l)
  PROJECTED=$(echo "$TOTAL_AUDIO / $RTF" | bc -l)

  echo
  bold "=== Result ==="
  info "$(hms "$BENCH_DUR") of audio took ${B_ELAPSED}s"
  printf '  speed: %.1fx realtime\n' "$RTF"
  printf '  projected time for all %d videos (%.1f hrs of audio): %s\n' \
         "${#FILES[@]}" "$(echo "$TOTAL_AUDIO/3600" | bc -l)" "$(hms "${PROJECTED%.*}")"
  echo
  info "Re-run without --benchmark to transcribe everything."
  echo
  exit 0
fi

OUTPUT_STAGE="$(mktemp -d "$DIR/.transcribe-mlx-work.XXXXXX")" \
  || die "Could not create a private staging directory beside the videos."
[ -n "$OUTPUT_STAGE" ] && [ -d "$OUTPUT_STAGE" ] \
  || die "Could not create a private staging directory beside the videos."
chmod 700 "$OUTPUT_STAGE" || die "Could not restrict staging directory permissions."

# ------------------------------------------------- plan the run (skip pass) --
bold ""
bold "=== Planning ==="

valid_json() {
  "$PY" -c 'import json, sys; data=json.load(open(sys.argv[1], encoding="utf8")); assert isinstance(data, dict); assert any(k in data for k in ("segments", "chunks", "text"))' \
    "$1" >/dev/null 2>&1
}

require_regular_or_absent() {
  local target="$1" description="$2"
  [ ! -L "$target" ] || die "$description may not be a symlink."
  [ ! -e "$target" ] || [ -f "$target" ] \
    || die "$description must be a regular file when it already exists."
}

atomic_replace() {
  "$PY" -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$1" "$2"
}

TODO=(); TODO_DUR=(); TODO_SIG=(); TODO_REBUILD=()
REMAINING=0; SKIPPED=0; REDO=0
for VIDEO in "${FILES[@]}"; do
  BASE="$(basename "$VIDEO")"
  STEM="${BASE%.*}"
  SAFE_BASE="$(safe_text "$BASE")"
  TXT="$DIR/$STEM.transcript.txt"
  JSON="$CACHE/.transcribe-mlx-$STEM.json"
  META="$CACHE/.transcribe-mlx-$STEM.meta"

  require_regular_or_absent "$TXT" "Transcript target for $SAFE_BASE"
  require_regular_or_absent "$JSON" "Cached JSON target for $SAFE_BASE"
  require_regular_or_absent "$META" "Cache metadata target for $SAFE_BASE"

  D="$(probe_duration "$VIDEO")" || die "Could not read the duration of: $SAFE_BASE"
  SIG="$(cache_signature "$VIDEO")" || die "Could not fingerprint: $SAFE_BASE"
  USE_CACHE=0
  CACHED_SIG=""
  CACHED_METADATA=""
  if [ "$FORCE" != "1" ] && [ -s "$JSON" ] && [ -s "$META" ] && valid_json "$JSON"; then
    {
      IFS= read -r CACHED_SIG || CACHED_SIG=""
      IFS= read -r CACHED_METADATA || CACHED_METADATA=""
    } < "$META"
    [ "$CACHED_SIG" = "$SIG" ] && USE_CACHE=1
  fi

  if [ -s "$TXT" ] && [ "$FORCE" != "1" ]; then
    if [ "$USE_CACHE" = "1" ] && [ "$CACHED_METADATA" = "$METADATA" ] \
      && QC="$("$PY" "$WORK/qc.py" "$TXT" "$JSON")"; then
        SKIPPED=$((SKIPPED+1))
        continue
    fi
    if [ "$USE_CACHE" = "1" ] && [ "$CACHED_METADATA" = "$METADATA" ]; then
      warn "$SAFE_BASE"
      warn "  previous transcript is ${QC##* }% one repeated unit — refreshing it"
      USE_CACHE=0
    elif [ "$USE_CACHE" = "1" ]; then
      warn "$SAFE_BASE — transcript metadata setting changed; refreshing it from cache"
    else
      warn "$SAFE_BASE — source or transcription settings changed; refreshing it"
    fi
    REDO=$((REDO+1))
  fi

  TODO+=("$VIDEO")
  TODO_DUR+=("$D")
  TODO_SIG+=("$SIG")
  if [ "$USE_CACHE" = "1" ]; then TODO_REBUILD+=(0); else TODO_REBUILD+=(1); fi
  REMAINING=$(echo "$REMAINING + $D" | bc -l)
done

if [ ${#TODO[@]} -eq 0 ]; then
  info "All ${#FILES[@]} videos already have transcripts. Nothing to do."
  info "(Use --force to redo them.)"
  exit 0
fi

info "${#FILES[@]} videos found — $SKIPPED already done, ${#TODO[@]} to transcribe"
[ "$REDO" -eq 0 ] || info "$REDO existing transcript(s) will be refreshed"
info "$(printf '%.1f' "$(echo "$REMAINING/3600" | bc -l)") hrs of audio ahead"
echo

# ------------------------------------------------------------------- run ----
RUN_START=$(date +%s)
DONE=0; FAILED=0; SUSPECT=0
FAILED_NAMES=(); SUSPECT_NAMES=()
PRIOR=0

for i in "${!TODO[@]}"; do
  VIDEO="${TODO[$i]}"
  DUR="${TODO_DUR[$i]}"
  SIG="${TODO_SIG[$i]}"
  REBUILD="${TODO_REBUILD[$i]}"
  BASE="$(basename "$VIDEO")"
  STEM="${BASE%.*}"
  SAFE_BASE="$(safe_text "$BASE")"
  SAFE_STEM="$(safe_text "$STEM")"
  TXT="$DIR/$STEM.transcript.txt"
  JSON="$CACHE/.transcribe-mlx-$STEM.json"
  META="$CACHE/.transcribe-mlx-$STEM.meta"

  PROG_DUR="$DUR"
  PROG_IDX=$((i+1))
  PROG_N=${#TODO[@]}
  PROG_PRIOR="$PRIOR"
  PROG_TOTAL="$REMAINING"
  PROG_NAME="$SAFE_BASE"

  FILE_START=$(date +%s)
  CURRENT_JSON="$JSON"

  if [ "$REBUILD" = "1" ]; then
    WAV="$WORK/audio.wav"
    [ -n "$WORK" ] && [ -d "$WORK" ] || die "Temporary work directory is unavailable."
    rm -rf "$WORK/out"
    mkdir -p "$WORK/out" || die "Could not create the temporary output directory."
    rm -f "$WAV"
    if ! ffmpeg -nostdin -v error -y -i "$VIDEO" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$WAV"; then
      warn "audio extraction failed — skipping $SAFE_BASE"
      FAILED=$((FAILED+1)); FAILED_NAMES+=("$BASE")
      PRIOR=$(echo "$PRIOR + $DUR" | bc -l)
      continue
    fi

    ACTIVE_JSON_TMP="$(mktemp "$CACHE/.transcribe-mlx-json.XXXXXX")" \
      || die "Could not create a temporary cache file."
    if ! run_mlx "$WAV" "$ACTIVE_JSON_TMP"; then
      warn "transcription failed — skipping $SAFE_BASE"
      rm -f "$ACTIVE_JSON_TMP"; ACTIVE_JSON_TMP=""
      FAILED=$((FAILED+1)); FAILED_NAMES+=("$BASE")
      PRIOR=$(echo "$PRIOR + $DUR" | bc -l)
      continue
    fi
    rm -f "$WAV"
    CURRENT_JSON="$ACTIVE_JSON_TMP"
  else
    info "$SAFE_BASE — reusing cached transcription data"
  fi

  if ! valid_json "$CURRENT_JSON"; then
    warn "transcription data is invalid — skipping $SAFE_BASE"
    if [ "$REBUILD" = "1" ]; then
      rm -f "$ACTIVE_JSON_TMP"; ACTIVE_JSON_TMP=""
    else
      rm -f "$META"
    fi
    FAILED=$((FAILED+1)); FAILED_NAMES+=("$BASE")
    PRIOR=$(echo "$PRIOR + $DUR" | bc -l)
    continue
  fi

  ACTIVE_TXT_TMP="$(mktemp "$OUTPUT_STAGE/transcript.XXXXXX")" \
    || die "Could not create a private temporary transcript."
  if ! STATS="$("$PY" "$WORK/to_txt.py" "$CURRENT_JSON" "$ACTIVE_TXT_TMP" \
      "$BASE" "$DUR" "$MODEL" "$METADATA")"; then
    warn "could not prepare the text file for $SAFE_BASE"
    rm -f "$ACTIVE_TXT_TMP"; ACTIVE_TXT_TMP=""
    if [ "$REBUILD" = "1" ]; then
      rm -f "$ACTIVE_JSON_TMP"; ACTIVE_JSON_TMP=""
    else
      rm -f "$META"
    fi
    FAILED=$((FAILED+1)); FAILED_NAMES+=("$BASE")
    PRIOR=$(echo "$PRIOR + $DUR" | bc -l)
    continue
  fi

  CANDIDATE_WORDS="${STATS##*, }"
  CANDIDATE_WORDS="${CANDIDATE_WORDS% words}"
  if [[ ! "$CANDIDATE_WORDS" =~ ^[0-9]+$ ]]; then
    warn "could not validate transcript statistics for $SAFE_BASE"
    rm -f "$ACTIVE_TXT_TMP"; ACTIVE_TXT_TMP=""
    if [ "$REBUILD" = "1" ]; then
      rm -f "$ACTIVE_JSON_TMP"; ACTIVE_JSON_TMP=""
    else
      rm -f "$META"
    fi
    FAILED=$((FAILED+1)); FAILED_NAMES+=("$BASE")
    PRIOR=$(echo "$PRIOR + $DUR" | bc -l)
    continue
  fi

  ELAPSED=$(( $(date +%s) - FILE_START ))
  [ "$ELAPSED" -lt 1 ] && ELAPSED=1

  QC_OK=0
  if [ "$CANDIDATE_WORDS" -eq 0 ] && [ -s "$TXT" ] \
    && "$PY" "$WORK/has_text.py" "$TXT" >/dev/null 2>&1; then
      QC="EMPTY 0"
  elif QC="$("$PY" "$WORK/qc.py" "$ACTIVE_TXT_TMP" "$CURRENT_JSON")"; then
    QC_OK=1
  fi

  if [ "$QC_OK" = "1" ]; then
    require_regular_or_absent "$TXT" "Transcript target for $SAFE_BASE"
    require_regular_or_absent "$JSON" "Cached JSON target for $SAFE_BASE"
    require_regular_or_absent "$META" "Cache metadata target for $SAFE_BASE"

    ACTIVE_META_TMP="$(mktemp "$CACHE/.transcribe-mlx-meta.XXXXXX")" \
      || die "Could not create temporary cache metadata."
    printf '%s\n%s\n' "$SIG" "$METADATA" > "$ACTIVE_META_TMP" \
      || die "Could not write temporary cache metadata."

    # META is the commit record. Remove it first so an interrupted multi-file
    # promotion can never look current on the next run.
    rm -f "$META" || die "Could not invalidate old cache metadata."
    atomic_replace "$ACTIVE_TXT_TMP" "$TXT" \
      || die "Could not publish the completed transcript."
    ACTIVE_TXT_TMP=""
    if [ "$REBUILD" = "1" ]; then
      atomic_replace "$ACTIVE_JSON_TMP" "$JSON" \
        || die "Could not update the transcription cache."
      ACTIVE_JSON_TMP=""
    fi
    atomic_replace "$ACTIVE_META_TMP" "$META" || die "Could not update cache metadata."
    ACTIVE_META_TMP=""
    printf '  %b✓%b %s  —  %s in %s (%.1fx)\n' \
           "$C_OK" "$C_RESET" "$SAFE_STEM.transcript.txt" "$STATS" "$(hms "$ELAPSED")" \
           "$(echo "${DUR%.*} / $ELAPSED" | bc -l)"
    DONE=$((DONE+1))
  else
    rm -f "$ACTIVE_TXT_TMP"; ACTIVE_TXT_TMP=""
    if [ "$REBUILD" = "1" ]; then
      rm -f "$ACTIVE_JSON_TMP"; ACTIVE_JSON_TMP=""
    else
      # Invalidate this cache entry so the next run does not reuse it.
      rm -f "$META"
    fi
    if [[ "$QC" = EMPTY* ]]; then
      warn "$SAFE_STEM.transcript.txt contained no recognized speech."
    else
      warn "$SAFE_STEM.transcript.txt looks suspect: ${QC##* }% is one repeated unit."
    fi
    warn "The previous transcript, if any, was left unchanged."
    warn "Retry with --force --no-prompt."
    SUSPECT=$((SUSPECT+1)); SUSPECT_NAMES+=("$BASE")
  fi
  echo
  PRIOR=$(echo "$PRIOR + $DUR" | bc -l)
done

TOTAL=$(( $(date +%s) - RUN_START ))
echo
bold "=== Finished in $(hms "$TOTAL") ==="
info "transcribed: $DONE    skipped: $SKIPPED    failed: $FAILED    suspect: $SUSPECT"
for n in "${FAILED_NAMES[@]:-}"; do [ -n "$n" ] && warn "failed: $(safe_text "$n")"; done
for n in "${SUSPECT_NAMES[@]:-}"; do [ -n "$n" ] && warn "suspect: $(safe_text "$n")"; done
echo
info "Transcripts are beside their source videos."
echo

[ "$FAILED" -eq 0 ] && [ "$SUSPECT" -eq 0 ] || exit 1
