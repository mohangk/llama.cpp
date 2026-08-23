#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${LLAMA_MODEL:-}"
MMPROJ="${LLAMA_MMPROJ:-}"
MTP_MODEL="${LLAMA_MTP_MODEL:-}"
PORT="${LLAMA_PORT:-8080}"
CTX_SIZE="${LLAMA_CTX_SIZE:-32768}"
THREADS="${LLAMA_THREADS:-6}"
THREADS_BATCH="${LLAMA_THREADS_BATCH:-${THREADS}}"
BATCH_SIZE="${LLAMA_BATCH_SIZE:-2048}"
UBATCH_SIZE="${LLAMA_UBATCH_SIZE:-512}"
FLASH_ATTN="${LLAMA_FLASH_ATTN:-on}"
GPU_LAYERS="${LLAMA_GPU_LAYERS:-999}"
SPEC_DRAFT_N_MAX="${LLAMA_SPEC_DRAFT_N_MAX:-3}"
TOOLS="read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_info"
OPTIONAL_ARGS=()

BUILD_DIR="${REPO_ROOT}/build-minipc-nvidia"
SERVER_BIN="${LLAMA_SERVER_BIN:-${BUILD_DIR}/bin/llama-server}"

if [[ -z "${MODEL}" ]]; then
    printf 'LLAMA_MODEL must contain an absolute path to a GGUF model.\n' >&2
    exit 2
fi

if [[ "${MODEL}" != /* ]] || [[ ! -r "${MODEL}" ]]; then
    printf 'LLAMA_MODEL is not a readable absolute path: %s\n' "${MODEL}" >&2
    exit 1
fi

if [[ ! -x "${SERVER_BIN}" ]]; then
    printf 'llama-server is not executable: %s\n' "${SERVER_BIN}" >&2
    printf 'Build it with: ./local-scripts/minipc-nvidia-build.sh baseline\n' >&2
    exit 1
fi

for value_name in PORT CTX_SIZE THREADS THREADS_BATCH BATCH_SIZE UBATCH_SIZE GPU_LAYERS SPEC_DRAFT_N_MAX; do
    value="${!value_name}"
    if ! [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s must be a positive integer.\n' "${value_name}" >&2
        exit 2
    fi
done

if (( PORT > 65535 )); then
    printf 'LLAMA_PORT must not exceed 65535.\n' >&2
    exit 2
fi

if [[ "${FLASH_ATTN}" != "on" && "${FLASH_ATTN}" != "off" && "${FLASH_ATTN}" != "auto" ]]; then
    printf 'LLAMA_FLASH_ATTN must be on, off, or auto.\n' >&2
    exit 2
fi

if [[ -n "${MMPROJ}" ]]; then
    if [[ "${MMPROJ}" != /* ]] || [[ ! -r "${MMPROJ}" ]]; then
        printf 'LLAMA_MMPROJ is not a readable absolute path: %s\n' "${MMPROJ}" >&2
        exit 1
    fi
    OPTIONAL_ARGS+=( --mmproj "${MMPROJ}" )
fi

if [[ -n "${MTP_MODEL}" ]]; then
    if [[ "${MTP_MODEL}" != /* ]] || [[ ! -r "${MTP_MODEL}" ]]; then
        printf 'LLAMA_MTP_MODEL is not a readable absolute path: %s\n' "${MTP_MODEL}" >&2
        exit 1
    fi
    OPTIONAL_ARGS+=(
        --spec-type draft-mtp
        --model-draft "${MTP_MODEL}"
        --device-draft CUDA0
        --gpu-layers-draft "${GPU_LAYERS}"
        --spec-draft-n-max "${SPEC_DRAFT_N_MAX}"
    )
fi

if [[ "${GGML_CUDA_ENABLE_UNIFIED_MEMORY:-0}" == "1" ]]; then
    printf 'WARNING: GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 can spill into system RAM and reduce performance.\n' >&2
fi

printf 'Web UI:  http://127.0.0.1:%s\n' "${PORT}"
printf 'Model:   %s\n' "${MODEL}"
printf 'Build:   baseline\n'
printf 'Device:  CUDA0\n'
printf 'Tools:   %s\n' "${TOOLS}"
printf 'WARNING: tools run with your user account permissions; approve only expected calls.\n'

cd "${REPO_ROOT}"

exec "${SERVER_BIN}" \
    --model "${MODEL}" \
    --device CUDA0 \
    --gpu-layers "${GPU_LAYERS}" \
    --flash-attn "${FLASH_ATTN}" \
    --ctx-size "${CTX_SIZE}" \
    --parallel 1 \
    --threads "${THREADS}" \
    --threads-batch "${THREADS_BATCH}" \
    --batch-size "${BATCH_SIZE}" \
    --ubatch-size "${UBATCH_SIZE}" \
    "${OPTIONAL_ARGS[@]}" \
    --jinja \
    --ui \
    --no-ui-mcp-proxy \
    --tools "${TOOLS}" \
    --host 127.0.0.1 \
    --port "${PORT}" \
    "$@"
