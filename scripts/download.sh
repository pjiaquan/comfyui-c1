#!/usr/bin/env bash
set -Eeuo pipefail

log() { echo "[INFO] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

PYTHON_BIN="${PYTHON_BIN:-python3}"
HF_BIN="${HF_BIN:-hf}"

REPO_ID=""
TARGET_DIR="."

# 解析參數
if [[ "$1" == http* ]]; then
    # 支援 URL 輸入（但整個 repo 較少用 URL）
    log "URL 輸入不支援下載整個 repo，請直接用 repo_id"
    exit 1
else
    REPO_ID="$1"
    TARGET_DIR="${2:-.}"
fi

if [ -z "$REPO_ID" ]; then
    echo "Usage:" >&2
    echo "  $0 <repo_id> [target_dir]" >&2
    echo "Example:" >&2
    echo "  $0 coder3101/Qwen3-VL-4B-Instruct-heretic ./qwen3-vl-4b-heretic" >&2
    exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    die "Python not found: $PYTHON_BIN"
fi

if ! command -v "$HF_BIN" >/dev/null 2>&1; then
    log "hf CLI not found, installing..."
    "$PYTHON_BIN" -m pip install --break-system-packages -U "huggingface_hub[cli,hf_transfer]"
fi

mkdir -p "$TARGET_DIR"

log "Downloading entire repository: $REPO_ID"
log "Target directory: $TARGET_DIR"

# 使用 snapshot_download 的 CLI 方式（最乾淨）
DOWNLOAD_CMD="$HF_BIN download \"$REPO_ID\" --local-dir \"$TARGET_DIR\" "

# 如果想加速，可以加上 hf_transfer（需先安裝）
if python3 -c "import hf_transfer" 2>/dev/null; then
    log "hf_transfer detected, enabling faster download..."
    export HF_HUB_ENABLE_HF_TRANSFER=1
fi

log "Running: $DOWNLOAD_CMD"
eval "$DOWNLOAD_CMD"

if [ $? -eq 0 ]; then
    log "✅ Download completed successfully!"
    log "Model saved to: $(realpath "$TARGET_DIR")"
    ls -lh "$TARGET_DIR" | head -20
else
    die "Download failed."
fi
