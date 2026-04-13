#!/usr/bin/env bash
set -Eeuo pipefail

INPUT_TARGET="${1:-}"
DEST_DIR="${2:-.}"
TOKEN="${3:-${CIVITAI_TOKEN:-}}"
EXPECTED_FILENAME="${4:-}"

log() { echo "[INFO] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

if [[ -z "$INPUT_TARGET" ]]; then
  die "Usage: $0 <model_version_id_or_url> [dest_dir] [token] [expected_filename]"
fi

if [[ -z "$TOKEN" ]]; then
  die "Missing token. Set CIVITAI_TOKEN or pass it as the 3rd argument."
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd curl || die "curl is required."
need_cmd awk || die "awk is required."
need_cmd mktemp || die "mktemp is required."
need_cmd ls || die "ls is required."

mkdir -p "$DEST_DIR"

if [[ "$INPUT_TARGET" =~ ^https?:// ]]; then
  DOWNLOAD_URL="$INPUT_TARGET"
  if [[ "$INPUT_TARGET" =~ /models/([0-9]+) ]]; then
    MODEL_VERSION_ID="${BASH_REMATCH[1]}"
  else
    MODEL_VERSION_ID="unknown_model"
  fi
else
  MODEL_VERSION_ID="$INPUT_TARGET"
  DOWNLOAD_URL="https://civitai.com/api/download/models/${MODEL_VERSION_ID}"
fi

TMP_HEADERS="$(mktemp)"
cleanup() {
  rm -f "$TMP_HEADERS"
}
trap cleanup EXIT

HEADER_FILENAME=""

if [[ -n "$EXPECTED_FILENAME" ]]; then
  log "Using expected filename: $EXPECTED_FILENAME"
  FILENAME="$EXPECTED_FILENAME"
else
  log "Resolving filename from headers..."

  if ! curl -sSIL \
    -H "Authorization: Bearer ${TOKEN}" \
    "$DOWNLOAD_URL" >"$TMP_HEADERS"; then
    curl -sS -D "$TMP_HEADERS" -o /dev/null -L -r 0-0 \
      -H "Authorization: Bearer ${TOKEN}" \
      "$DOWNLOAD_URL" >/dev/null || die "Failed to fetch response headers from Civitai."
  fi

  HEADER_FILENAME="$(
    awk '
      BEGIN { IGNORECASE=1 }
      /^content-disposition:/ {
        line=$0
        sub(/\r$/, "", line)

        if (match(line, /filename\*=UTF-8'\'''\''[^;]+/)) {
          val=substr(line, RSTART, RLENGTH)
          sub(/^filename\*=UTF-8'\'''\''/, "", val)
          print val
          exit
        }

        if (match(line, /filename="[^"]+"/)) {
          val=substr(line, RSTART, RLENGTH)
          sub(/^filename="/, "", val)
          sub(/"$/, "", val)
          print val
          exit
        }

        if (match(line, /filename=[^;]+/)) {
          val=substr(line, RSTART, RLENGTH)
          sub(/^filename=/, "", val)
          gsub(/^[ \t]+|[ \t]+$/, "", val)
          print val
          exit
        }
      }
    ' "$TMP_HEADERS"
  )"

  if [[ -n "$HEADER_FILENAME" ]]; then
    FILENAME="$HEADER_FILENAME"
    log "Resolved filename from headers: $FILENAME"
  else
    FILENAME="${MODEL_VERSION_ID}.bin"
    log "No filename found in headers, fallback to: $FILENAME"
  fi
fi

TARGET_PATH="${DEST_DIR}/${FILENAME}"
PART_PATH="${TARGET_PATH}.part"

log "Downloading model version: ${MODEL_VERSION_ID}"
log "Final path: ${TARGET_PATH}"
log "Temp path:  ${PART_PATH}"

if [[ -s "$TARGET_PATH" ]]; then
  log "File already exists and is non-empty, skipping."
  exit 0
fi

if [[ -f "$TARGET_PATH" && ! -s "$TARGET_PATH" ]]; then
  log "Found empty target file, removing: $TARGET_PATH"
  rm -f "$TARGET_PATH"
fi

if [[ -f "$PART_PATH" && ! -s "$PART_PATH" ]]; then
  log "Found empty partial file, removing: $PART_PATH"
  rm -f "$PART_PATH"
fi

CURL_RESUME_ARGS=()
if [[ -s "$PART_PATH" ]]; then
  log "Found partial file, resuming download..."
  CURL_RESUME_ARGS=(-C -)
else
  log "Starting fresh download..."
fi

curl -fL \
  "${CURL_RESUME_ARGS[@]}" \
  --retry 10 \
  --retry-delay 5 \
  --retry-all-errors \
  -H "Authorization: Bearer ${TOKEN}" \
  -o "$PART_PATH" \
  "$DOWNLOAD_URL" || die "Download failed."

if [[ ! -s "$PART_PATH" ]]; then
  rm -f "$PART_PATH"
  die "Downloaded file is empty."
fi

mv -f "$PART_PATH" "$TARGET_PATH"

if [[ ! -s "$TARGET_PATH" ]]; then
  rm -f "$TARGET_PATH"
  die "Final file is empty after move."
fi

log "Done:"
log "  $TARGET_PATH"
ls -lh "$TARGET_PATH" >&2
