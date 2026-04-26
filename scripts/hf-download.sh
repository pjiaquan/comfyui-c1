#!/usr/bin/env bash
set -Eeuo pipefail

log() { echo "[INFO] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

PYTHON_BIN="${PYTHON_BIN:-/opt/venv/bin/python}"
HF_BIN="${HF_BIN:-/opt/venv/bin/hf}"
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

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  die "Python not found: $PYTHON_BIN"
fi

if [[ "${HF_AUTO_UPDATE,,}" =~ ^(1|true|yes|on)$ ]]; then
  log "Updating Hugging Face CLI before download..."
  if ! "$PYTHON_BIN" -m pip install --break-system-packages -U "huggingface_hub[cli]"; then
    log "Hugging Face CLI update failed. Continuing with installed version if available."
  fi
fi

if ! command -v "$HF_BIN" >/dev/null 2>&1; then
  log "hf CLI not found, installing..."
  "$PYTHON_BIN" -m pip install --break-system-packages -U "huggingface_hub[cli]"
fi

if ! command -v "$HF_BIN" >/dev/null 2>&1; then
  die "hf CLI not found after install/update: $HF_BIN"
fi

if [ -n "${HF_TOKEN:-}" ]; then
  log "HF_TOKEN detected. Authenticated download is enabled."
else
  log "No HF_TOKEN detected. If this is a private/gated model, download might fail."
fi

mkdir -p "$TARGET_DIR"

EXPECTED_PATH_1="$TARGET_DIR/$(basename "$REPO_FILE")"
EXPECTED_PATH_2="$TARGET_DIR/$REPO_FILE"

if [ -s "$EXPECTED_PATH_1" ]; then
  log "File already exists, skipping: $EXPECTED_PATH_1"
  exit 0
fi

if [ -s "$EXPECTED_PATH_2" ]; then
  log "File already exists, skipping: $EXPECTED_PATH_2"
  exit 0
fi

log "Downloading: $REPO_FILE"
log "From Repo:  $REPO_ID"
log "To Dir:     $TARGET_DIR"

DOWNLOADED_PATH="$("$HF_BIN" download "$REPO_ID" "$REPO_FILE" \
  --local-dir "$TARGET_DIR" | tail -n 1)"

if [ -z "$DOWNLOADED_PATH" ] || [ ! -f "$DOWNLOADED_PATH" ] || [ ! -s "$DOWNLOADED_PATH" ]; then
  die "Download failed."
fi

FINAL_PATH="${TARGET_DIR}/$(basename "$REPO_FILE")"

if [ "$DOWNLOADED_PATH" != "$FINAL_PATH" ]; then
  mv -f "$DOWNLOADED_PATH" "$FINAL_PATH"
  
  # Clean up residual empty directories created by Hugging Face CLI when path has subfolders
  CURRENT_DIR="$(dirname "$DOWNLOADED_PATH")"
  TARGET_DIR_ABS="$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")"
  
  while [ -n "$CURRENT_DIR" ] && [ "$CURRENT_DIR" != "." ] && [ "$CURRENT_DIR" != "/" ]; do
    CURRENT_DIR_ABS="$(cd "$CURRENT_DIR" 2>/dev/null && pwd || echo "$CURRENT_DIR")"
    if [ "$CURRENT_DIR_ABS" = "$TARGET_DIR_ABS" ]; then
      break
    fi
    rmdir "$CURRENT_DIR" 2>/dev/null || break
    CURRENT_DIR="$(dirname "$CURRENT_DIR")"
  done
fi

log "Success: $FINAL_PATH"
