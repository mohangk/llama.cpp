#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${1:-baseline}"
CUDA_ROOT="${LLAMA_CUDA_ROOT:-/usr/local/cuda-13.2}"
CC_BIN="${LLAMA_CC:-/usr/bin/gcc-15}"
CXX_BIN="${LLAMA_CXX:-/usr/bin/g++-15}"
BUILD_JOBS="${LLAMA_BUILD_JOBS:-16}"
CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER="${CC_BIN}"
    -DCMAKE_CXX_COMPILER="${CXX_BIN}"
    -DCMAKE_CUDA_COMPILER="${CUDA_ROOT}/bin/nvcc"
    -DCMAKE_CUDA_HOST_COMPILER="${CXX_BIN}"
    -DCMAKE_CUDA_ARCHITECTURES=86-real
    -DGGML_CUDA=ON
    -DGGML_CUDA_FA=ON
    -DGGML_CUDA_GRAPHS=ON
    -DGGML_NATIVE=ON
    -DGGML_CUDA_FORCE_MMQ=OFF
    -DGGML_CUDA_FORCE_CUBLAS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=ON
    -DLLAMA_BUILD_UI=OFF
)

case "${VARIANT}" in
    baseline)
        BUILD_DIR="${REPO_ROOT}/build-minipc-nvidia"
        ;;
    no-graphs)
        BUILD_DIR="${REPO_ROOT}/build-minipc-nvidia-no-graphs"
        CMAKE_ARGS+=( -DGGML_CUDA_GRAPHS=OFF )
        ;;
    force-cublas)
        BUILD_DIR="${REPO_ROOT}/build-minipc-nvidia-force-cublas"
        CMAKE_ARGS+=( -DGGML_CUDA_FORCE_CUBLAS=ON )
        ;;
    *)
        printf 'Usage: %s [baseline|no-graphs|force-cublas]\n' "$0" >&2
        exit 2
        ;;
esac

if ! [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'LLAMA_BUILD_JOBS must be a positive integer.\n' >&2
    exit 2
fi

for command_name in cmake nvidia-smi; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "${command_name}" >&2
        exit 1
    fi
done

if [[ ! -x "${CUDA_ROOT}/bin/nvcc" ]]; then
    printf 'CUDA compiler is not executable: %s\n' "${CUDA_ROOT}/bin/nvcc" >&2
    exit 1
fi

if [[ ! -x "${CC_BIN}" ]] || [[ ! -x "${CXX_BIN}" ]]; then
    printf 'CUDA 13.2 requires the GCC 15 C and C++ compatibility compilers.\n' >&2
    printf 'Install them with: sudo dnf install gcc15 gcc15-c++\n' >&2
    exit 1
fi

if ! nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader | grep -Fq 'NVIDIA GeForce RTX 3090, 8.6'; then
    printf 'Expected NVIDIA GeForce RTX 3090 with compute capability 8.6 was not found.\n' >&2
    exit 1
fi

printf 'Variant:   %s\n' "${VARIANT}"
printf 'Build dir: %s\n' "${BUILD_DIR}"
printf 'CUDA:      %s\n' "${CUDA_ROOT}"
printf 'Host C++:  %s\n' "${CXX_BIN}"
printf 'Jobs:      %s\n' "${BUILD_JOBS}"

cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" "${CMAKE_ARGS[@]}"
cmake --build "${BUILD_DIR}" --target llama-cli llama-bench llama-server -j "${BUILD_JOBS}"

"${BUILD_DIR}/bin/llama-cli" --version
"${BUILD_DIR}/bin/llama-cli" --list-devices
