#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_BIN="${LLAMA_SERVER_BIN:-${REPO_ROOT}/build-vulkan-amd/bin/llama-server}"
MODEL="${LLAMA_MODEL:-${HOME}/models/gemma-4-12B-qat/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf}"
MTP_MODEL="${LLAMA_MTP_MODEL:-$(dirname -- "${MODEL}")/mtp-gemma-4-12B-it.gguf}"
PORT="${LLAMA_PORT:-8080}"
CTX_SIZE="${LLAMA_CTX_SIZE:-32768}"
SPEC_DRAFT_N_MAX="${LLAMA_SPEC_DRAFT_N_MAX:-3}"
ENABLE_MTP="${LLAMA_ENABLE_MTP:-1}"
VULKAN_ICD="/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"
TOOLS="read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_datetime"
MTP_ARGS=()

if [[ ! -x "${SERVER_BIN}" ]]; then
    printf 'llama-server is not executable: %s\n' "${SERVER_BIN}" >&2
    printf 'Build it with: cmake --build build-vulkan-amd --target llama-server -j 16\n' >&2
    exit 1
fi

if [[ ! -f "${MODEL}" ]]; then
    printf 'Model file not found: %s\n' "${MODEL}" >&2
    printf 'Set LLAMA_MODEL to the GGUF model path.\n' >&2
    exit 1
fi

if [[ "${ENABLE_MTP}" != "0" && "${ENABLE_MTP}" != "1" ]]; then
    printf 'LLAMA_ENABLE_MTP must be 0 or 1.\n' >&2
    exit 1
fi

if [[ ! -r "${VULKAN_ICD}" ]]; then
    printf 'Vulkan ICD is not readable: %s\n' "${VULKAN_ICD}" >&2
    exit 1
fi

if [[ ! "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    printf 'LLAMA_PORT must be an integer from 1 to 65535.\n' >&2
    exit 1
fi

if [[ ! "${CTX_SIZE}" =~ ^[0-9]+$ ]] || (( CTX_SIZE < 1 )); then
    printf 'LLAMA_CTX_SIZE must be a positive integer.\n' >&2
    exit 1
fi

if [[ "${ENABLE_MTP}" == "1" ]]; then
    if [[ ! -f "${MTP_MODEL}" ]]; then
        printf 'MTP model file not found: %s\n' "${MTP_MODEL}" >&2
        printf 'Set LLAMA_MTP_MODEL to the Gemma 4 MTP GGUF path.\n' >&2
        exit 1
    fi

    if [[ ! "${SPEC_DRAFT_N_MAX}" =~ ^[0-9]+$ ]] || (( SPEC_DRAFT_N_MAX < 1 )); then
        printf 'LLAMA_SPEC_DRAFT_N_MAX must be a positive integer.\n' >&2
        exit 1
    fi

    MTP_ARGS=(
        --spec-type draft-mtp
        --model-draft "${MTP_MODEL}"
        --device-draft Vulkan0
        --gpu-layers-draft 99
        --spec-draft-n-max "${SPEC_DRAFT_N_MAX}"
    )
fi

export VK_DRIVER_FILES="${VULKAN_ICD}"

printf 'Web UI: http://127.0.0.1:%s\n' "${PORT}"
if [[ "${ENABLE_MTP}" == "1" ]]; then
    printf 'MTP:    %s (up to %s draft tokens)\n' "${MTP_MODEL}" "${SPEC_DRAFT_N_MAX}"
else
    printf 'MTP:    disabled\n'
fi
printf 'Tools:  %s\n' "${TOOLS}"
printf 'WARNING: tools run with your user account permissions; approve only expected calls.\n'

cd "${REPO_ROOT}"

exec "${SERVER_BIN}" \
    --model "${MODEL}" \
    --device Vulkan0 \
    --gpu-layers 99 \
    --flash-attn auto \
    --ctx-size "${CTX_SIZE}" \
    --parallel 1 \
    "${MTP_ARGS[@]}" \
    --jinja \
    --ui \
    --no-ui-mcp-proxy \
    --tools "${TOOLS}" \
    --host 127.0.0.1 \
    --port "${PORT}"
