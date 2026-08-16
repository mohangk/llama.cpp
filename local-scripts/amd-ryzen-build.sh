#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build-vulkan-amd"
BUILD_JOBS="${LLAMA_BUILD_JOBS:-16}"
VULKAN_ICD="${LLAMA_VULKAN_ICD:-/usr/share/vulkan/icd.d/radeon_icd.x86_64.json}"

if ! [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'LLAMA_BUILD_JOBS must be a positive integer.\n' >&2
    exit 2
fi

for command_name in cmake glslc vulkaninfo; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "${command_name}" >&2
        exit 1
    fi
done

if [[ ! -r "${VULKAN_ICD}" ]]; then
    printf 'Vulkan ICD is not readable: %s\n' "${VULKAN_ICD}" >&2
    exit 1
fi

export VK_DRIVER_FILES="${VULKAN_ICD}"

if ! vulkaninfo --summary 2>/dev/null | grep -Fq 'AMD Radeon 860M Graphics'; then
    printf 'Expected AMD Radeon 860M Graphics Vulkan device was not found.\n' >&2
    exit 1
fi

printf 'Build dir:  %s\n' "${BUILD_DIR}"
printf 'Vulkan ICD: %s\n' "${VULKAN_ICD}"
printf 'Jobs:       %s\n' "${BUILD_JOBS}"

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=ON \
    -DGGML_HIP=OFF \
    -DGGML_NATIVE=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_UI=OFF

cmake --build "${BUILD_DIR}" --target llama-cli llama-bench llama-server -j "${BUILD_JOBS}"

"${BUILD_DIR}/bin/llama-cli" --version
"${BUILD_DIR}/bin/llama-cli" --list-devices
