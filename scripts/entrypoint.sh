#!/usr/bin/env bash
set -Eeuo pipefail

COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
PYTHON_BIN="${PYTHON_BIN:-${VENV_DIR}/bin/python}"
MANIFEST_PATH="${MANIFEST_PATH:-/opt/config/models.manifest}"

log() { echo "[ENTRYPOINT] $*"; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

cleanup() {
  echo "[ENTRYPOINT] shutting down..."
  if [[ -n "${ST_PID:-}" ]]; then
    kill "$ST_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT TERM INT

mkdir -p \
  "${COMFY_DIR}/models/checkpoints" \
  "${COMFY_DIR}/models/text_encoders" \
  "${COMFY_DIR}/models/vae" \
  "${COMFY_DIR}/models/loras" \
  "${COMFY_DIR}/models/unet" \
  "${COMFY_DIR}/input" \
  "${COMFY_DIR}/output"

need_file() {
  local path="$1"
  [[ -s "$path" ]]
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

  log "Downloading from HF: ${filename}"
  log "HF source URL: ${url}"
  log "HF expected file: ${outdir}/${filename}"

  /opt/bin/hf-download.sh "${url}" "${outdir}"

  if ! need_file "${outdir}/${filename}"; then
    log "ERROR: expected file missing after HF download: ${outdir}/${filename}"
    exit 1
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
  /opt/bin/civitai-download.sh "${model_version_id}" "${outdir}" "${CIVITAI_TOKEN:-}" "${expected_name}"

  if ! need_file "${outdir}/${expected_name}"; then
    log "ERROR: expected file missing after Civitai download: ${outdir}/${expected_name}"
    exit 1
  fi
}

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

process_manifest() {
  local manifest="$1"

  [[ -f "$manifest" ]] || {
    log "ERROR: manifest not found: $manifest"
    exit 1
  }

  while IFS='|' read -r type source dest filename env_flag; do
    type="$(trim "${type:-}")"
    source="$(trim "${source:-}")"
    dest="$(trim "${dest:-}")"
    filename="$(trim "${filename:-}")"
    env_flag="$(trim "${env_flag:-}")"

    [[ -z "${type:-}" ]] && continue
    [[ "${type:0:1}" == "#" ]] && continue

    if [[ -z "$filename" ]]; then
      filename="$(infer_filename "$type" "$source")"
    fi

    case "$type" in
      HF)
        [[ -n "$filename" ]] || { log "ERROR: filename cannot be inferred for $source"; exit 1; }
        download_hf_url_if_missing "$source" "$dest" "$filename"
        ;;
      CIVITAI)
        [[ -n "$filename" ]] || { log "ERROR: CIVITAI requires filename: $source"; exit 1; }
        download_civitai_if_missing "$source" "$dest" "$filename"
        ;;
      HF_OPTIONAL)
        if [[ -n "${env_flag:-}" && "${!env_flag:-0}" == "1" ]]; then
          [[ -n "$filename" ]] || { log "ERROR: filename cannot be inferred for $source"; exit 1; }
          download_hf_url_if_missing "$source" "$dest" "$filename"
        else
          log "Skipping optional HF model: ${filename:-$source}"
        fi
        ;;
      CIVITAI_OPTIONAL)
        if [[ -n "${env_flag:-}" && "${!env_flag:-0}" == "1" ]]; then
          [[ -n "$filename" ]] || { log "ERROR: CIVITAI requires filename: $source"; exit 1; }
          download_civitai_if_missing "$source" "$dest" "$filename"
        else
          log "Skipping optional Civitai model: ${filename:-$source}"
        fi
        ;;
      *)
        log "ERROR: unknown manifest type: $type"
        exit 1
        ;;
    esac
  done < "$manifest"
}



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

process_manifest() {
  local manifest="$1"

  [[ -f "$manifest" ]] || {
    log "ERROR: manifest not found: $manifest"
    exit 1
  }

  while IFS='|' read -r type source dest filename env_flag; do
    type="$(trim "${type:-}")"
    source="$(trim "${source:-}")"
    dest="$(trim "${dest:-}")"
    filename="$(trim "${filename:-}")"
    env_flag="$(trim "${env_flag:-}")"

    [[ -z "${type:-}" ]] && continue
    [[ "${type:0:1}" == "#" ]] && continue

    if [[ -z "$filename" ]]; then
      filename="$(infer_filename "$type" "$source")"
    fi

    case "$type" in
      HF)
        [[ -n "$filename" ]] || { log "ERROR: filename cannot be inferred for $source"; exit 1; }
        download_hf_url_if_missing "$source" "$dest" "$filename"
        ;;
      CIVITAI)
        [[ -n "$filename" ]] || { log "ERROR: CIVITAI requires filename: $source"; exit 1; }
        download_civitai_if_missing "$source" "$dest" "$filename"
        ;;
      HF_OPTIONAL)
        if [[ -n "${env_flag:-}" && "${!env_flag:-0}" == "1" ]]; then
          [[ -n "$filename" ]] || { log "ERROR: filename cannot be inferred for $source"; exit 1; }
          download_hf_url_if_missing "$source" "$dest" "$filename"
        else
          log "Skipping optional HF model: ${filename:-$source}"
        fi
        ;;
      CIVITAI_OPTIONAL)
        if [[ -n "${env_flag:-}" && "${!env_flag:-0}" == "1" ]]; then
          [[ -n "$filename" ]] || { log "ERROR: CIVITAI requires filename: $source"; exit 1; }
          download_civitai_if_missing "$source" "$dest" "$filename"
        else
          log "Skipping optional Civitai model: ${filename:-$source}"
        fi
        ;;
      *)
        log "ERROR: unknown manifest type: $type"
        exit 1
        ;;
    esac
  done < "$manifest"
}

process_manifest "${MANIFEST_PATH}"

# 啟動輔助程序
if [[ "${ENABLE_ST:-1}" == "1" ]]; then
  ${VENV_DIR}/bin/python3 /opt/bin/st.py &
  ST_PID=$!

  sleep 1
  if ! kill -0 "$ST_PID" 2>/dev/null; then
    echo "[ENTRYPOINT] st.py failed to start" >&2
    exit 1
  fi
fi

EXTRA_ARGS=()

if [[ "${ENABLE_MANAGER:-0}" == "1" ]]; then
  EXTRA_ARGS+=(--enable-manager)
fi

cd "${COMFY_DIR}"
exec "${PYTHON_BIN}" main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --normalvram \
  "${EXTRA_ARGS[@]}" \
  "$@"
