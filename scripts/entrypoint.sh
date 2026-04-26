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
VRAM_MODE="${VRAM_MODE:-auto}"
FAIL_FAST="${FAIL_FAST:-0}"
MANIFEST_REQUIRED="${MANIFEST_REQUIRED:-1}"
ENABLE_ST="${ENABLE_ST:-1}"
ENABLE_MANAGER="${ENABLE_MANAGER:-1}"
ST_START_TIMEOUT="${ST_START_TIMEOUT:-1}"
TELEGRAM_ERROR_LOGS="${TELEGRAM_ERROR_LOGS:-1}"
TELEGRAM_ERROR_LOG_MAX_CHARS="${TELEGRAM_ERROR_LOG_MAX_CHARS:-3500}"
TELEGRAM_ERROR_LOG_TIMEOUT="${TELEGRAM_ERROR_LOG_TIMEOUT:-10}"
TELEGRAM_ERROR_LOG_NAME="${TELEGRAM_ERROR_LOG_NAME:-ComfyUI entrypoint}"
TELEGRAM_ERROR_LOG_RETRIES="${TELEGRAM_ERROR_LOG_RETRIES:-2}"
TELEGRAM_ERROR_LOG_MAX_RETRY_AFTER="${TELEGRAM_ERROR_LOG_MAX_RETRY_AFTER:-30}"

if ! [[ "$TELEGRAM_ERROR_LOG_MAX_CHARS" =~ ^[0-9]+$ ]] || ((TELEGRAM_ERROR_LOG_MAX_CHARS <= 0)); then
  TELEGRAM_ERROR_LOG_MAX_CHARS=3500
fi

if ! [[ "$TELEGRAM_ERROR_LOG_TIMEOUT" =~ ^[0-9]+$ ]] || ((TELEGRAM_ERROR_LOG_TIMEOUT <= 0)); then
  TELEGRAM_ERROR_LOG_TIMEOUT=10
fi

if ! [[ "$TELEGRAM_ERROR_LOG_RETRIES" =~ ^[0-9]+$ ]]; then
  TELEGRAM_ERROR_LOG_RETRIES=2
fi

if ! [[ "$TELEGRAM_ERROR_LOG_MAX_RETRY_AFTER" =~ ^[0-9]+$ ]] || ((TELEGRAM_ERROR_LOG_MAX_RETRY_AFTER <= 0)); then
  TELEGRAM_ERROR_LOG_MAX_RETRY_AFTER=30
fi

FAILED_DOWNLOADS=()
LAST_ERROR_LOG_FILE=""
LAST_ERROR_STATUS=0
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
  notify_telegram_error "$*"
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

telegram_bot_token() {
  printf '%s' "${MyD3_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
}

telegram_chat_id() {
  printf '%s' "${MyD3_TELEGRAM_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"
}

telegram_retry_after() {
  local response_file="$1"

  sed -n 's/.*"retry_after"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' "$response_file" | head -n 1
}

notify_telegram_error() {
  local message="$1"
  local details_file="${2:-}"
  local token=""
  local chat_id=""
  local details=""
  local text=""
  local response_file=""
  local http_code=""
  local attempt=0
  local retry_after=0
  local sleep_seconds=0

  is_truthy "$TELEGRAM_ERROR_LOGS" || return 0

  token="$(telegram_bot_token)"
  chat_id="$(telegram_chat_id)"
  if [[ -z "$token" || -z "$chat_id" ]]; then
    return 0
  fi

  if ! need_cmd curl; then
    printf '[ENTRYPOINT] WARNING: curl not found; cannot send Telegram error log.\n' >&2
    return 0
  fi

  if [[ -n "$details_file" && -s "$details_file" ]]; then
    details="$(tail -c "$TELEGRAM_ERROR_LOG_MAX_CHARS" "$details_file" 2>/dev/null || true)"
  fi

  text="$(printf '[%s] ERROR\n%s' "$TELEGRAM_ERROR_LOG_NAME" "$message")"
  if [[ -n "$details" ]]; then
    text="${text}"$'\n\n'"Last output:"$'\n'"${details}"
  fi

  if ((${#text} > TELEGRAM_ERROR_LOG_MAX_CHARS)); then
    text="${text:0:TELEGRAM_ERROR_LOG_MAX_CHARS}"$'\n'"... truncated"
  fi

  response_file="$(mktemp -t telegram-error-log.XXXXXX 2>/dev/null || true)"
  if [[ -z "$response_file" ]]; then
    printf '[ENTRYPOINT] WARNING: mktemp failed; cannot send Telegram error log.\n' >&2
    return 0
  fi

  while ((attempt <= TELEGRAM_ERROR_LOG_RETRIES)); do
    http_code=""
    if ! http_code="$(curl -sS --max-time "$TELEGRAM_ERROR_LOG_TIMEOUT" \
      -o "$response_file" \
      -w '%{http_code}' \
      --data-urlencode "chat_id=${chat_id}" \
      --data-urlencode "text=${text}" \
      "https://api.telegram.org/bot${token}/sendMessage")"; then
      printf '[ENTRYPOINT] WARNING: Failed to send Telegram error log.\n' >&2
      rm -f "$response_file"
      return 0
    fi

    if [[ "$http_code" =~ ^2 ]]; then
      rm -f "$response_file"
      return 0
    fi

    if [[ "$http_code" == "429" && "$attempt" -lt "$TELEGRAM_ERROR_LOG_RETRIES" ]]; then
      retry_after="$(telegram_retry_after "$response_file")"
      if ! [[ "$retry_after" =~ ^[0-9]+$ ]] || ((retry_after <= 0)); then
        retry_after=1
      fi

      sleep_seconds=$retry_after
      if ((sleep_seconds > TELEGRAM_ERROR_LOG_MAX_RETRY_AFTER)); then
        sleep_seconds=$TELEGRAM_ERROR_LOG_MAX_RETRY_AFTER
      fi

      printf '[ENTRYPOINT] WARNING: Telegram rate limited error log; retrying in %ss.\n' "$sleep_seconds" >&2
      sleep "$sleep_seconds"
      attempt=$((attempt + 1))
      continue
    fi

    printf '[ENTRYPOINT] WARNING: Failed to send Telegram error log (HTTP %s): %s\n' "$http_code" "$(tr '\n' ' ' < "$response_file" 2>/dev/null)" >&2
    rm -f "$response_file"
    return 0
  done

  rm -f "$response_file"
}

on_unhandled_error() {
  local status="$1"
  local line="$2"
  notify_telegram_error "Unhandled entrypoint error at line ${line} (exit code ${status})"
}

run_with_error_log() {
  local output_file=""
  local command_status=0
  local restore_errexit=0

  LAST_ERROR_LOG_FILE=""
  LAST_ERROR_STATUS=0

  output_file="$(mktemp -t entrypoint-error-log.XXXXXX 2>/dev/null || true)"
  if [[ -z "$output_file" ]]; then
    if "$@"; then
      return 0
    else
      LAST_ERROR_STATUS=$?
      return "$LAST_ERROR_STATUS"
    fi
  fi

  case "$-" in
    *e*)
      restore_errexit=1
      set +e
      ;;
  esac

  "$@" 2>&1 | tee "$output_file"
  command_status=${PIPESTATUS[0]}

  if ((restore_errexit)); then
    set -e
  fi

  if ((command_status == 0)); then
    rm -f "$output_file"
    return 0
  fi

  LAST_ERROR_STATUS=$command_status
  LAST_ERROR_LOG_FILE="$output_file"
  return "$LAST_ERROR_STATUS"
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
  local details_file="${2:-}"
  FAILED_DOWNLOADS+=("$message")
  warn "$message"
  notify_telegram_error "$message" "$details_file"
  if is_truthy "$FAIL_FAST"; then
    exit 1
  fi
}

cleanup() {
  if [[ -n "${ST_PID:-}" ]]; then
    log "Stopping st.py (pid ${ST_PID})"
    kill "${ST_PID}" 2>/dev/null || true
    wait "${ST_PID}" 2>/dev/null || true
  fi
}

trap cleanup EXIT TERM INT
trap 'on_unhandled_error "$?" "$LINENO"' ERR

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

  if ! run_with_error_log "${HF_DOWNLOAD_BIN}" "${url}" "${outdir}"; then
    record_failure "Hugging Face download failed for ${filename} (exit code ${LAST_ERROR_STATUS})" "$LAST_ERROR_LOG_FILE"
    [[ -z "$LAST_ERROR_LOG_FILE" ]] || rm -f "$LAST_ERROR_LOG_FILE"
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

  if [[ -n "$expected_name" ]] && need_file "${outdir}/${expected_name}"; then
    log "Exists: ${outdir}/${expected_name}"
    return 0
  fi

  log "Downloading from Civitai: ${expected_name:-$model_version_id}"

  if ! run_with_error_log "${CIVITAI_DOWNLOAD_BIN}" "${model_version_id}" "${outdir}" "${CIVITAI_TOKEN:-}" "${expected_name}"; then
    record_failure "Civitai download failed for ${expected_name:-$model_version_id} (exit code ${LAST_ERROR_STATUS})" "$LAST_ERROR_LOG_FILE"
    [[ -z "$LAST_ERROR_LOG_FILE" ]] || rm -f "$LAST_ERROR_LOG_FILE"
    return 0
  fi

  if [[ -n "$expected_name" ]] && ! need_file "${outdir}/${expected_name}"; then
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

  if [[ -z "${MyD3_TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    export MyD3_TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
  fi

  if [[ -z "${MyD3_TELEGRAM_CHAT_ID:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    export MyD3_TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
  fi

  if [[ -z "${MyD3_TELEGRAM_BOT_TOKEN:-}" || -z "${MyD3_TELEGRAM_CHAT_ID:-}" ]]; then
    warn "Telegram credentials (MyD3_TELEGRAM_BOT_TOKEN/MyD3_TELEGRAM_CHAT_ID) missing. Skipping st.py helper."
    return 0
  fi

  if [[ ! -e "$ST_PY_PATH" ]]; then
    local message="st.py helper not found: ${ST_PY_PATH}. Continuing without st.py."
    warn "$message"
    notify_telegram_error "$message"
    return 0
  fi

  if [[ "$ST_PYTHON_BIN" == */* ]]; then
    if [[ ! -e "$ST_PYTHON_BIN" ]]; then
      local message="st.py Python interpreter not found: ${ST_PYTHON_BIN}. Continuing without st.py."
      warn "$message"
      notify_telegram_error "$message"
      return 0
    fi
  elif ! need_cmd "$ST_PYTHON_BIN"; then
    local message="st.py Python interpreter not found on PATH: ${ST_PYTHON_BIN}. Continuing without st.py."
    warn "$message"
    notify_telegram_error "$message"
    return 0
  fi

  log "Starting st.py helper"
  "${ST_PYTHON_BIN}" "${ST_PY_PATH}" &
  ST_PID=$!

  while (( waited < ST_START_TIMEOUT )); do
    sleep 1
    waited=$((waited + 1))

    if ! kill -0 "$ST_PID" 2>/dev/null; then
      local status=0
      local message=""
      wait "$ST_PID" || status=$?
      message="st.py failed during startup (exit code ${status}). Continuing without st.py."
      warn "$message"
      notify_telegram_error "$message"
      ST_PID=""
      return 0
    fi
  done

  if ! kill -0 "$ST_PID" 2>/dev/null; then
    local status=0
    local message=""
    wait "$ST_PID" || status=$?
    message="st.py is not running after startup (exit code ${status}). Continuing without st.py."
    warn "$message"
    notify_telegram_error "$message"
    ST_PID=""
    return 0
  fi

  log "st.py started successfully (pid ${ST_PID})"
}

build_comfy_command() {
  local -n _cmd_ref=$1

  if [[ "$VRAM_MODE" == "auto" ]]; then
    if need_cmd nvidia-smi; then
      local vram_mb
      vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{print $1}' | head -n 1)
      if [[ -n "$vram_mb" && "$vram_mb" =~ ^[0-9]+$ ]]; then
        if (( vram_mb >= 16000 )); then
          VRAM_MODE="highvram"
        elif (( vram_mb < 8000 )); then
          VRAM_MODE="lowvram"
        else
          VRAM_MODE="normalvram"
        fi
        log "Auto-detected GPU with ${vram_mb}MB VRAM. Using ${VRAM_MODE} mode."
      else
        VRAM_MODE="normalvram"
        warn "Could not parse VRAM from nvidia-smi. Falling back to normalvram."
      fi
    else
      VRAM_MODE="cpu"
      log "nvidia-smi not found. Falling back to cpu mode."
    fi
  fi

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
