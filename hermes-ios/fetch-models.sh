#!/usr/bin/env bash
set -euo pipefail

# Downloads the on-device Whisper speech-to-text model bundled by the iOS app.
#
# The Xcode project references HermesApp/Resources/whisper-base as a folder
# resource, but the model (~147 MB) is not checked into git. Run this script
# once after cloning, before building the app.
#
# Sources:
#   - CoreML model:  https://huggingface.co/argmaxinc/whisperkit-coreml
#                    (openai_whisper-base, MIT licensed)
#   - Tokenizer:     https://huggingface.co/openai/whisper-base
#                    (Apache-2.0 licensed)

HF_BASE="https://huggingface.co"
COREML_REPO="argmaxinc/whisperkit-coreml"
COREML_DIR="openai_whisper-base"
TOKENIZER_REPO="openai/whisper-base"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest_dir="$script_dir/HermesApp/Resources/whisper-base"

say() {
  printf '%s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "Missing required command: $1"
    exit 1
  fi
}

require_cmd curl
require_cmd python3

if [[ -f "$dest_dir/TextDecoder.mlmodelc/weights/weight.bin" && -f "$dest_dir/tokenizer.json" ]]; then
  say "Whisper model already present at:"
  say "  $dest_dir"
  say "Delete that directory and re-run this script to force a fresh download."
  exit 0
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

say "Fetching model file list from $COREML_REPO..."
file_list="$(curl -fsSL "$HF_BASE/api/models/$COREML_REPO/tree/main/$COREML_DIR?recursive=true" \
  | python3 -c 'import json,sys
for entry in json.load(sys.stdin):
    if entry.get("type") == "file":
        print(entry["path"])')"

if [[ -z "$file_list" ]]; then
  say "Could not list model files from Hugging Face. Check your network and retry."
  exit 1
fi

download() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  say "  $url"
  curl -fSL --retry 3 --progress-bar "$url" -o "$out"
  if [[ ! -s "$out" ]]; then
    say "Downloaded file is empty: $out"
    exit 1
  fi
}

say "Downloading Whisper CoreML model (~147 MB)..."
while IFS= read -r path; do
  rel="${path#"$COREML_DIR"/}"
  download "$HF_BASE/$COREML_REPO/resolve/main/$path" "$work_dir/whisper-base/$rel"
done <<< "$file_list"

say "Downloading tokenizer..."
for f in tokenizer.json tokenizer_config.json; do
  download "$HF_BASE/$TOKENIZER_REPO/resolve/main/$f" "$work_dir/whisper-base/$f"
done

for required in \
  "MelSpectrogram.mlmodelc" "AudioEncoder.mlmodelc" "TextDecoder.mlmodelc" \
  "config.json" "generation_config.json" "tokenizer.json" "tokenizer_config.json"; do
  if [[ ! -e "$work_dir/whisper-base/$required" ]]; then
    say "Download is missing expected item: $required"
    exit 1
  fi
done

rm -rf "$dest_dir"
mkdir -p "$(dirname "$dest_dir")"
mv "$work_dir/whisper-base" "$dest_dir"

say
say "Whisper model installed:"
say "  $dest_dir"
say "You can now build HermesApp.xcodeproj in Xcode."
