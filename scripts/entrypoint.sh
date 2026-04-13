#!/usr/bin/env bash
set -Eeuo pipefail

COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
PYTHON_BIN="${PYTHON_BIN:-${VENV_DIR}/bin/python}"
MANIFEST_PATH="${MANIFEST_PATH:-/opt/config/models.manifest}"
HF_DOWNLOAD_BIN="${HF_DOWNLOAD_BIN:-/opt/bin/hf-download.sh}"
CIVITAI_DOWNLOAD_BIN="${CIVITAI_DOWNLOAD_BIN:-/opt/bin/civitai-download.sh}"
ST_PY_PATH="${ST_PY_PATH:-/opt/bin/st.py}"
ST_PYTHON_BIN="${ST_PYTHON_BIN:-${VENV_DIR}/bin/python3}"
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"
PORT="${PORT:-8188}"
VRAM_MODE="${VRAM_MODE:-normalvram}"
FAIL_FAST="${FAIL_FAST:-0}"
MANIFEST_REQUIRED="${MANIFEST_REQUIRED:-1}"
ENABLE_ST="${ENABLE_ST:-1}"
ENABLE_MANAGER="${ENABLE_MANAGER:-0}"
ST_START_TIMEOUT="${ST_START_TIMEOUT:-1}"

FAILED_DOWNLOADS=()
ST_PID=""

log() {
  printf '[ENTRYPOINT] %s\n' "$*"
}

warn() {
  printf '[ENTRYPOINT] WARNING: %s\n' "$*" >&2
}

error() {
  printf '[ENTRYPOINT] ERROR: %s\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

need_file() {
  local path="$1"
  [[ -s "$path" ]]
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_path() {
  local path="$1"
  local description="$2"
  [[ -e "$path" ]] || die "${description} not found: ${path}"
}

ensure_executable() {
  local path="$1"
  local description="$2"
  [[ -x "$path" ]] || die "${description} is not executable: ${path}"
}

record_failure() {
  local message="$1"
  FAILED_DOWNLOADS+=("$message")
  if is_truthy "$FAIL_FAST"; then
    die "$message"
  fi
  warn "$message"
}

cleanup() {
  if [[ -n "${ST_PID:-}" ]]; then
    log "Stopping st.py (pid ${ST_PID})"
    kill "${ST_PID}" 2>/dev/null || true
    wait "${ST_PID}" 2>/dev/null || true
  fi
}

trap cleanup EXIT TERM INT

infer_filename() {
  local type="$1"
  local source="$2"

  case "$type" in
    HF|HF_OPTIONAL)
      basename "${source%%\?*}"
      ;;
    CIVITAI|CIVITAI_OPTIONAL)
      printf ''
      ;;
    *)
      printf ''
      ;;
  esac
}

download_hf_url_if_missing() {
  local url="$1"
  local outdir="$2"
  local filename="$3"

  mkdir -p "$outdir"

  if need_file "${outdir}/${filename}"; then
    log "Exists: ${outdir}/${filename}"
    return 0
  fi

  log "Downloading from Hugging Face: ${filename}"
  log "Source URL: ${url}"

  if ! "${HF_DOWNLOAD_BIN}" "${url}" "${outdir}"; then
    record_failure "Hugging Face download failed for ${filename}"
    return 0
  fi

  if ! need_file "${outdir}/${filename}"; then
    record_failure "Expected file missing after Hugging Face download: ${outdir}/${filename}"
  fi
}

download_civitai_if_missing() {
  local model_version_id="$1"
  local outdir="$2"
  local expected_name="$3"

  mkdir -p "$outdir"

  if need_file "${outdir}/${expected_name}"; then
    log "Exists: ${outdir}/${expected_name}"
    return 0
  fi

  log "Downloading from Civitai: ${expected_name}"

  if ! "${CIVITAI_DOWNLOAD_BIN}" "${model_version_id}" "${outdir}" "${CIVITAI_TOKEN:-}" "${expected_name}"; then
    record_failure "Civitai download failed for ${expected_name}"
    return 0
  fi

  if ! need_file "${outdir}/${expected_name}"; then
    record_failure "Expected file missing after Civitai download: ${outdir}/${expected_name}"
  fi
}

should_download_optional() {
  local env_flag="$1"
  [[ -n "$env_flag" ]] && is_truthy "${!env_flag:-0}"
}

process_manifest_line() {
  local line_no="$1"
  local type="$2"
  local source="$3"
  local dest="$4"
  local filename="$5"
  local env_flag="$6"

  if [[ -z "$type" ]]; then
    return 0
  fi

  if [[ "${type:0:1}" == "#" ]]; then
    return 0
  fi

  [[ -n "$source" ]] || die "Manifest line ${line_no}: source is required"
  [[ -n "$dest" ]] || die "Manifest line ${line_no}: destination is required"

  if [[ -z "$filename" ]]; then
    filename="$(infer_filename "$type" "$source")"
  fi

  case "$type" in
    HF)
      [[ -n "$filename" ]] || die "Manifest line ${line_no}: filename cannot be inferred for ${source}"
      download_hf_url_if_missing "$source" "$dest" "$filename"
      ;;
    CIVITAI)
      [[ -n "$filename" ]] || die "Manifest line ${line_no}: CIVITAI requires an explicit filename"
      download_civitai_if_missing "$source" "$dest" "$filename"
      ;;
    HF_OPTIONAL)
      [[ -n "$env_flag" ]] || die "Manifest line ${line_no}: HF_OPTIONAL requires an env flag"
      if should_download_optional "$env_flag"; then
        [[ -n "$filename" ]] || die "Manifest line ${line_no}: filename cannot be inferred for ${source}"
        download_hf_url_if_missing "$source" "$dest" "$filename"
      else
        log "Skipping optional Hugging Face model on line ${line_no}: ${filename:-$source}"
      fi
      ;;
    CIVITAI_OPTIONAL)
      [[ -n "$env_flag" ]] || die "Manifest line ${line_no}: CIVITAI_OPTIONAL requires an env flag"
      if should_download_optional "$env_flag"; then
        [[ -n "$filename" ]] || die "Manifest line ${line_no}: CIVITAI_OPTIONAL requires an explicit filename"
        download_civitai_if_missing "$source" "$dest" "$filename"
      else
        log "Skipping optional Civitai model on line ${line_no}: ${filename:-$source}"
      fi
      ;;
    *)
      die "Manifest line ${line_no}: unknown type '${type}'"
      ;;
  esac
}

process_manifest() {
  local manifest="$1"
  local line_no=0
  local line=""

  if [[ ! -f "$manifest" ]]; then
    if is_truthy "$MANIFEST_REQUIRED"; then
      die "Manifest not found: ${manifest}"
    fi
    warn "Manifest not found, skipping downloads: ${manifest}"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    local type=""
    local source=""
    local dest=""
    local filename=""
    local env_flag=""

    line_no=$((line_no + 1))
    line="$(trim "$line")"

    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    IFS='|' read -r type source dest filename env_flag _extra <<< "$line"

    type="$(trim "${type:-}")"
    source="$(trim "${source:-}")"
    dest="$(trim "${dest:-}")"
    filename="$(trim "${filename:-}")"
    env_flag="$(trim "${env_flag:-}")"

    process_manifest_line "$line_no" "$type" "$source" "$dest" "$filename" "$env_flag"
  done < "$manifest"
}

start_st() {
  local waited=0

  if [[ -z "${MyD3_TELEGRAM_BOT_TOKEN:-}" || -z "${MyD3_TELEGRAM_CHAT_ID:-}" ]]; then
    warn "Telegram credentials (MyD3_TELEGRAM_BOT_TOKEN/MyD3_TELEGRAM_CHAT_ID) missing. Skipping st.py helper."
    return 0
  fi

  require_path "$ST_PY_PATH" "st.py helper"
  log "Starting st.py helper"
  "${ST_PYTHON_BIN}" "${ST_PY_PATH}" &
  ST_PID=$!

  while (( waited < ST_START_TIMEOUT )); do
    sleep 1
    waited=$((waited + 1))

    if ! kill -0 "$ST_PID" 2>/dev/null; then
      wait "$ST_PID" || true
      die "st.py failed during startup"
    fi
  done

  if ! kill -0 "$ST_PID" 2>/dev/null; then
    wait "$ST_PID" || true
    die "st.py is not running after startup"
  fi

  log "st.py started successfully (pid ${ST_PID})"
}

build_comfy_command() {
  local -n _cmd_ref=$1
  _cmd_ref=(
    "${PYTHON_BIN}" main.py
    --listen "${LISTEN_HOST}"
    --port "${PORT}"
  )

  case "$VRAM_MODE" in
    normalvram|lowvram|novram|highvram|gpu-only|cpu)
      _cmd_ref+=("--${VRAM_MODE}")
      ;;
    "")
      ;;
    *)
      die "Unsupported VRAM_MODE: ${VRAM_MODE}"
      ;;
  esac

  if is_truthy "$ENABLE_MANAGER"; then
    _cmd_ref+=(--enable-manager)
  fi
}

main() {
  local comfy_cmd=()

  if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
    log "Executing custom command without ComfyUI bootstrap: $*"
    exec "$@"
  fi

  require_path "$COMFY_DIR" "ComfyUI directory"
  require_path "$PYTHON_BIN" "Python interpreter"
  require_path "$HF_DOWNLOAD_BIN" "Hugging Face downloader"
  require_path "$CIVITAI_DOWNLOAD_BIN" "Civitai downloader"
  ensure_executable "$HF_DOWNLOAD_BIN" "Hugging Face downloader"
  ensure_executable "$CIVITAI_DOWNLOAD_BIN" "Civitai downloader"

  mkdir -p \
    "${COMFY_DIR}/models/checkpoints" \
    "${COMFY_DIR}/models/text_encoders" \
    "${COMFY_DIR}/models/vae" \
    "${COMFY_DIR}/models/loras" \
    "${COMFY_DIR}/models/unet" \
    "${COMFY_DIR}/models/diffusion_models" \
    "${COMFY_DIR}/input" \
    "${COMFY_DIR}/output"

  process_manifest "${MANIFEST_PATH}"

  if ((${#FAILED_DOWNLOADS[@]} > 0)); then
    warn "Completed with ${#FAILED_DOWNLOADS[@]} download issue(s)"
    printf '[ENTRYPOINT] WARNING: %s\n' "${FAILED_DOWNLOADS[@]}" >&2
  fi

  if is_truthy "$ENABLE_ST"; then
    start_st
  fi

  build_comfy_command comfy_cmd

  if [[ $# -gt 0 ]]; then
    comfy_cmd+=("$@")
  fi

  cd "${COMFY_DIR}"
  log "Launching ComfyUI: ${comfy_cmd[*]}"
  exec "${comfy_cmd[@]}"
}

main "$@"
