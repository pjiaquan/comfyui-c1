#!/usr/bin/env bash
set -Eeuo pipefail

log() { echo "[INFO] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

PYTHON_BIN="${PYTHON_BIN:-/opt/venv/bin/python}"
HF_AUTO_UPDATE="${HF_AUTO_UPDATE:-1}"

INPUT_1="${1:-}"
INPUT_2="${2:-}"
INPUT_3="${3:-}"

REPO_ID=""
REPO_FILE=""
TARGET_DIR=""

if [[ "$INPUT_1" == http* ]]; then
  log "Detected Hugging Face URL, parsing..."
  URL_PATH="${INPUT_1#*huggingface.co/}"
  REPO_ID=$(echo "$URL_PATH" | sed -E 's#/(blob|resolve)/[^/]+/.+##')
  REPO_FILE=$(echo "$URL_PATH" | sed -E 's#.*/(blob|resolve)/[^/]+/##')
  TARGET_DIR="${INPUT_2:-.}"
else
  REPO_ID="$INPUT_1"
  REPO_FILE="$INPUT_2"
  TARGET_DIR="$INPUT_3"
fi

if [ -z "$REPO_ID" ] || [ -z "$REPO_FILE" ] || [ -z "$TARGET_DIR" ]; then
  echo "Usage: $0 <URL> [target_dir]" >&2
  echo "   or: $0 <repo_id> <repo_file> <target_dir>" >&2
  exit 1
fi

REPO_FILE="${REPO_FILE%%\?*}"
FINAL_PATH="${TARGET_DIR}/$(basename "$REPO_FILE")"
NESTED_PATH="${TARGET_DIR}/${REPO_FILE}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  die "Python not found: $PYTHON_BIN"
fi

if [[ "${HF_AUTO_UPDATE,,}" =~ ^(1|true|yes|on)$ ]]; then
  log "Updating Hugging Face Hub before download..."
  if ! "$PYTHON_BIN" -m pip install --break-system-packages -U "huggingface_hub"; then
    log "Hugging Face Hub update failed. Continuing with installed version if available."
  fi
fi

if ! "$PYTHON_BIN" -c "import huggingface_hub" >/dev/null 2>&1; then
  log "huggingface_hub not found, installing..."
  "$PYTHON_BIN" -m pip install --break-system-packages -U "huggingface_hub"
fi

if ! "$PYTHON_BIN" -c "import huggingface_hub" >/dev/null 2>&1; then
  die "huggingface_hub not found after install/update."
fi

if [ -n "${HF_TOKEN:-}" ]; then
  log "HF_TOKEN detected. Authenticated download is enabled."
else
  log "No HF_TOKEN detected. If this is a private/gated model, download might fail."
fi

mkdir -p "$TARGET_DIR"

cleanup_empty_dirs() {
  local current_dir="$1"
  local target_dir_abs=""
  local current_dir_abs=""

  target_dir_abs="$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")"

  while [ -n "$current_dir" ] && [ "$current_dir" != "." ] && [ "$current_dir" != "/" ]; do
    current_dir_abs="$(cd "$current_dir" 2>/dev/null && pwd || echo "$current_dir")"
    if [ "$current_dir_abs" = "$target_dir_abs" ]; then
      break
    fi
    rmdir "$current_dir" 2>/dev/null || break
    current_dir="$(dirname "$current_dir")"
  done
}

absolute_path() {
  local path="$1"
  local dir=""
  local base=""
  local dir_abs=""

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  dir_abs="$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")"
  printf '%s/%s' "$dir_abs" "$base"
}

flatten_downloaded_file() {
  local source_path="$1"
  local source_abs=""
  local final_abs=""

  if [ ! -f "$source_path" ] || [ ! -s "$source_path" ]; then
    return 1
  fi

  source_abs="$(absolute_path "$source_path")"
  final_abs="$(absolute_path "$FINAL_PATH")"

  if [ "$source_abs" != "$final_abs" ]; then
    log "Flattening downloaded file: ${source_path} -> ${FINAL_PATH}"
    mv -f "$source_path" "$FINAL_PATH"
    cleanup_empty_dirs "$(dirname "$source_path")"
  fi

  return 0
}

if [ -s "$FINAL_PATH" ]; then
  log "File already exists, skipping: $FINAL_PATH"
  exit 0
fi

if [ -s "$NESTED_PATH" ]; then
  flatten_downloaded_file "$NESTED_PATH" || die "Failed to flatten existing download: $NESTED_PATH"
  log "Success: $FINAL_PATH"
  exit 0
fi

log "Downloading: $REPO_FILE"
log "From Repo:  $REPO_ID"
log "To Dir:     $TARGET_DIR"

DOWNLOAD_OUTPUT="$(mktemp -t hf-download-output.XXXXXX)"
if ! "$PYTHON_BIN" - "$REPO_ID" "$REPO_FILE" "$TARGET_DIR" <<'PY' | tee "$DOWNLOAD_OUTPUT"; then
import os
import sys

from huggingface_hub import hf_hub_download

repo_id, repo_file, target_dir = sys.argv[1:4]
downloaded_path = hf_hub_download(
    repo_id=repo_id,
    filename=repo_file,
    local_dir=target_dir,
    token=os.environ.get("HF_TOKEN") or None,
)
print(downloaded_path)
PY
  rm -f "$DOWNLOAD_OUTPUT"
  die "Download failed."
fi

DOWNLOADED_PATH="$(tail -n 1 "$DOWNLOAD_OUTPUT")"
rm -f "$DOWNLOAD_OUTPUT"

if flatten_downloaded_file "$NESTED_PATH"; then
  log "Success: $FINAL_PATH"
  exit 0
fi

if flatten_downloaded_file "$DOWNLOADED_PATH"; then
  log "Success: $FINAL_PATH"
  exit 0
fi

if flatten_downloaded_file "$FINAL_PATH"; then
  log "Success: $FINAL_PATH"
  exit 0
fi

die "Download completed, but expected file was not found: ${FINAL_PATH} or ${NESTED_PATH}"
