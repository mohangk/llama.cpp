#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${1:-baseline}"
MODE="${2:-core}"
MODEL="${LLAMA_MODEL:-}"
STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${LLAMA_RESULTS_DIR:-${STATE_ROOT}/llama.cpp/benchmarks/minipc-nvidia/${TIMESTAMP}-${VARIANT}-${MODE}}"

case "${VARIANT}" in
    baseline) BUILD_DIR="${REPO_ROOT}/build-minipc-nvidia" ;;
    no-graphs) BUILD_DIR="${REPO_ROOT}/build-minipc-nvidia-no-graphs" ;;
    force-cublas) BUILD_DIR="${REPO_ROOT}/build-minipc-nvidia-force-cublas" ;;
    *)
        printf 'Usage: %s [baseline|no-graphs|force-cublas] [smoke|core|tune]\n' "$0" >&2
        exit 2
        ;;
esac

if [[ "${MODE}" != "smoke" && "${MODE}" != "core" && "${MODE}" != "tune" ]]; then
    printf 'Usage: %s [baseline|no-graphs|force-cublas] [smoke|core|tune]\n' "$0" >&2
    exit 2
fi

BENCH_BIN="${BUILD_DIR}/bin/llama-bench"
CLI_BIN="${BUILD_DIR}/bin/llama-cli"
CACHE_FILE="${BUILD_DIR}/CMakeCache.txt"

if [[ -z "${MODEL}" ]]; then
    printf 'LLAMA_MODEL must contain an absolute path to a GGUF model.\n' >&2
    exit 2
fi

if [[ "${MODEL}" != /* ]] || [[ ! -r "${MODEL}" ]]; then
    printf 'LLAMA_MODEL is not a readable absolute path: %s\n' "${MODEL}" >&2
    exit 1
fi

if [[ ! -x "${BENCH_BIN}" ]] || [[ ! -x "${CLI_BIN}" ]]; then
    printf 'Required benchmark binaries are not executable in: %s/bin\n' "${BUILD_DIR}" >&2
    printf 'Build it with: ./local-scripts/minipc-nvidia-build.sh %s\n' "${VARIANT}" >&2
    exit 1
fi

for command_name in git nvidia-smi python3 sha256sum; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "${command_name}" >&2
        exit 1
    fi
done

mkdir -p "${RESULT_DIR}"

MODEL_SHA256="$(sha256sum "${MODEL}" | awk '{print $1}')"
MODEL_SIZE="$(stat -c '%s' "${MODEL}")"
GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"

"${CLI_BIN}" --version > "${RESULT_DIR}/binary-version.txt" 2>&1
nvidia-smi -q > "${RESULT_DIR}/nvidia-before.txt"
if [[ -r "${CACHE_FILE}" ]]; then
    grep -E '^(CMAKE_BUILD_TYPE|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_CUDA_ARCHITECTURES|CMAKE_CUDA_COMPILER|CMAKE_CUDA_HOST_COMPILER|GGML_CUDA|GGML_CUDA_FA|GGML_CUDA_GRAPHS|GGML_CUDA_FORCE_MMQ|GGML_CUDA_FORCE_CUBLAS|GGML_NATIVE|LLAMA_BUILD_SERVER|LLAMA_BUILD_TESTS|LLAMA_BUILD_UI):' "${CACHE_FILE}" > "${RESULT_DIR}/cmake-options.txt"
fi

python3 - "${RESULT_DIR}/metadata.json" "${TIMESTAMP}" "${VARIANT}" "${MODE}" "${MODEL}" "${MODEL_SIZE}" "${MODEL_SHA256}" "${GIT_COMMIT}" <<'PY'
import json
import sys

output, timestamp, variant, mode, model, size, sha256, commit = sys.argv[1:]
with open(output, "w", encoding="utf-8") as handle:
    json.dump({
        "timestamp_utc": timestamp,
        "machine": "minipc-nvidia",
        "variant": variant,
        "mode": mode,
        "model": model,
        "model_size": int(size),
        "model_sha256": sha256,
        "git_commit": commit,
    }, handle, indent=2)
    handle.write("\n")
PY

nvidia-smi --query-gpu=timestamp,pstate,utilization.gpu,utilization.memory,memory.used,power.draw,temperature.gpu,pcie.link.gen.current,pcie.link.width.current --format=csv --loop-ms=500 > "${RESULT_DIR}/nvidia-telemetry.csv" 2>&1 &
TELEMETRY_PID=$!
cleanup() {
    kill "${TELEMETRY_PID}" >/dev/null 2>&1 || true
    wait "${TELEMETRY_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

COMMON_ARGS=(
    --model "${MODEL}"
    --device CUDA0
    --n-gpu-layers 999
    --mmap 1
    --repetitions 5
    --output json
    --progress
)
RESULT_FILES=()

case "${MODE}" in
    smoke)
        "${BENCH_BIN}" "${COMMON_ARGS[@]}" --repetitions 1 --n-prompt 128 --n-gen 32 --threads 6 --flash-attn on --batch-size 2048 --ubatch-size 512 > "${RESULT_DIR}/smoke.json" 2> "${RESULT_DIR}/smoke.log"
        RESULT_FILES+=( "${RESULT_DIR}/smoke.json" )
        ;;
    core)
        "${BENCH_BIN}" "${COMMON_ARGS[@]}" --n-prompt 512,2048 --n-gen 128 --threads 6 --flash-attn on --batch-size 2048 --ubatch-size 512 > "${RESULT_DIR}/core.json" 2> "${RESULT_DIR}/core.log"
        RESULT_FILES+=( "${RESULT_DIR}/core.json" )
        ;;
    tune)
        "${BENCH_BIN}" "${COMMON_ARGS[@]}" --n-prompt 512,2048 --n-gen 128 --threads 6,12,22 --flash-attn on,off --batch-size 2048 --ubatch-size 512 > "${RESULT_DIR}/runtime.json" 2> "${RESULT_DIR}/runtime.log"
        "${BENCH_BIN}" "${COMMON_ARGS[@]}" --n-prompt 2048 --n-gen 0 --threads 6 --flash-attn on --batch-size 512,1024,2048 --ubatch-size 128,256,512 > "${RESULT_DIR}/batch.json" 2> "${RESULT_DIR}/batch.log"
        RESULT_FILES+=( "${RESULT_DIR}/runtime.json" "${RESULT_DIR}/batch.json" )
        ;;
esac

cleanup
trap - EXIT
nvidia-smi -q > "${RESULT_DIR}/nvidia-after.txt"

python3 - "${RESULT_DIR}/summary.md" "${RESULT_FILES[@]}" <<'PY'
import json
import sys

output = sys.argv[1]
rows = []
for filename in sys.argv[2:]:
    with open(filename, encoding="utf-8") as handle:
        rows.extend(json.load(handle))

with open(output, "w", encoding="utf-8") as handle:
    handle.write("| Test | Threads | Batch | Ubatch | FA | Average tok/s | Stddev |\n")
    handle.write("| --- | ---: | ---: | ---: | --- | ---: | ---: |\n")
    for row in rows:
        if row["n_prompt"]:
            test = f"pp{row['n_prompt']}"
        else:
            test = f"tg{row['n_gen']}"
        flash_attn = {-1: "auto", 0: "off", 1: "on"}.get(row["flash_attn"], str(row["flash_attn"]))
        handle.write(f"| {test} | {row['n_threads']} | {row['n_batch']} | {row['n_ubatch']} | {flash_attn} | {row['avg_ts']:.2f} | {row['stddev_ts']:.2f} |\n")
PY

cat "${RESULT_DIR}/summary.md"
printf '\nResults: %s\n' "${RESULT_DIR}"
