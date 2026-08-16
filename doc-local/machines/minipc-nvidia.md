# NVIDIA mini PC profile

This profile targets interactive single-user llama.cpp use on the Intel mini PC with an NVIDIA RTX 3090. CUDA is the production backend for the first tuning pass. Intel Vulkan and mixed-device execution are deferred.

## Hardware snapshot

The system inspected on 2026-08-15 had:

- OS: Fedora Linux 44 Workstation
- Kernel: Linux 7.1.8-200.fc44.x86_64
- CPU: Intel Core Ultra 9 185H, 16 physical cores and 22 threads
- CPU layout: 6 performance cores with Hyper-Threading, 8 efficiency cores, and 2 low-power efficiency cores
- CPU features: AVX2, AVX-VNNI, F16C, and FMA
- Integrated GPU: Intel Meteor Lake Arc Graphics using `i915`
- Discrete GPU: NVIDIA GeForce RTX 3090, compute capability 8.6
- NVIDIA memory: 24576 MiB physical, about 24123 MiB exposed to llama.cpp
- NVIDIA driver: 610.57.04
- CUDA compiler: CUDA 13.2, `nvcc` 13.2.86
- CUDA host compiler: GCC 15 compatibility compiler; Fedora GCC 16 is not supported by CUDA 13.2
- System memory: 93 GiB usable
- PCIe capability: Gen4 x16; the GPU negotiated Gen4 x8 under benchmark load
- Repository revision at inspection: `5af85cd76`

An older external llama.cpp build successfully enumerated `CUDA0`, VMM support, and 24123 MiB VRAM. This validates the driver and runtime path but is not benchmark evidence for the current checkout.

## Benchmark artifact

The local benchmark target is:

```text
/home/mohan/.lmstudio/models/unsloth/Qwen3.6-27B-MTP-GGUF/Qwen3.6-27B-Q4_K_M.gguf
```

Validated identity:

- GGUF version: 3
- Size: 17106773120 bytes
- SHA-256: `a7cbd3ecc0e3f9b333edee61ae66bc87ed713c5d49587a8355814722ed329e0f`
- Partial files: none

The directory also contains `mmproj-F32.gguf` at 1842940480 bytes. The core compilation benchmark uses only the text model so projector memory does not affect comparisons.

## Build profiles

Install the supported CUDA host compiler before the first build:

```bash
sudo dnf install gcc15 gcc15-c++
```

CUDA 13.2 rejects Fedora 44's default GCC 16. Do not bypass this check with `--allow-unsupported-compiler`.

Build the production baseline:

```bash
./local-scripts/minipc-nvidia-build.sh baseline
```

The baseline build directory is `build-minipc-nvidia`. It uses:

```text
CMAKE_BUILD_TYPE=Release
CMAKE_C_COMPILER=/usr/bin/gcc-15
CMAKE_CXX_COMPILER=/usr/bin/g++-15
CMAKE_CUDA_COMPILER=/usr/local/cuda-13.2/bin/nvcc
CMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-15
CMAKE_CUDA_ARCHITECTURES=86-real
GGML_CUDA=ON
GGML_CUDA_FA=ON
GGML_CUDA_GRAPHS=ON
GGML_NATIVE=ON
GGML_CUDA_FORCE_MMQ=OFF
GGML_CUDA_FORCE_CUBLAS=OFF
LLAMA_BUILD_TESTS=OFF
LLAMA_BUILD_SERVER=ON
LLAMA_BUILD_UI=OFF
```

The baseline is the only retained build. The script can recreate isolated comparison builds when a new llama.cpp revision, CUDA toolkit, or driver justifies retesting:

```bash
./local-scripts/minipc-nvidia-build.sh no-graphs
./local-scripts/minipc-nvidia-build.sh force-cublas
```

`no-graphs` disables CUDA graphs. `force-cublas` forces cuBLAS instead of the default RTX-tuned quantized matrix kernels. These comparison directories are temporary and are not required to run the server. Forced MMQ is not tested because Ampere already has integer tensor cores and the default selection is the appropriate baseline.

Set `LLAMA_BUILD_JOBS` to change the default 16 parallel build jobs. Set `LLAMA_CUDA_ROOT` only when intentionally selecting another CUDA toolkit.

## Benchmark workflow

Set the model once:

```bash
export LLAMA_MODEL=/home/mohan/.lmstudio/models/unsloth/Qwen3.6-27B-MTP-GGUF/Qwen3.6-27B-Q4_K_M.gguf
```

Validate the retained baseline with a short run:

```bash
./local-scripts/minipc-nvidia-bench.sh baseline smoke
```

For future build-option investigations, recreate and compare variants with the fixed core workload:

```bash
./local-scripts/minipc-nvidia-bench.sh baseline core
./local-scripts/minipc-nvidia-bench.sh no-graphs core
./local-scripts/minipc-nvidia-bench.sh force-cublas core
```

Run the runtime matrix on the selected baseline:

```bash
./local-scripts/minipc-nvidia-bench.sh baseline tune
```

Each result directory contains model and build metadata, raw llama-bench JSON, a Markdown summary, NVIDIA state before and after, and 500 ms NVIDIA telemetry. The telemetry records active PCIe generation and width along with utilization, power, temperature, and memory use.

Select a non-baseline build only when it improves generation throughput by at least 3 percent, reduces prompt throughput by no more than 5 percent, adds less than 1 GiB VRAM use, and passes deterministic output checks. For runtime settings, prioritize generation throughput. When generation results differ by less than 3 percent, choose the setting with better 2048-token prompt throughput.

## Server launcher

The launcher requires a model and defaults to the production baseline:

```bash
LLAMA_MODEL=/absolute/path/to/model.gguf \
  ./local-scripts/minipc-nvidia-run.sh
```

Optional multimodal and MTP artifacts are supplied independently:

```bash
LLAMA_MODEL=/absolute/path/to/model.gguf \
LLAMA_MMPROJ=/absolute/path/to/mmproj.gguf \
LLAMA_MTP_MODEL=/absolute/path/to/mtp.gguf \
  ./local-scripts/minipc-nvidia-run.sh
```

Supported overrides include:

- `LLAMA_CTX_SIZE`: default `32768`
- `LLAMA_THREADS` and `LLAMA_THREADS_BATCH`: default `6`
- `LLAMA_BATCH_SIZE`: default `2048`
- `LLAMA_UBATCH_SIZE`: default `512`
- `LLAMA_FLASH_ATTN`: default `on`
- `LLAMA_GPU_LAYERS`: default `999`
- `LLAMA_PORT`: default `8080`
- `LLAMA_SPEC_DRAFT_N_MAX`: default `3`

Additional positional arguments are appended to the llama-server command. The launcher binds to loopback, uses one server slot, and does not enable CUDA unified-memory spilling. It prints a warning when spilling was enabled in the inherited environment.

## Result record

The three compilation variants were measured at revision `5af85cd76` with five repetitions per core test. All results use full CUDA offload, six CPU threads, flash attention, batch 2048, and microbatch 512.

| Variant | pp512 tok/s | pp2048 tok/s | tg128 tok/s | Peak VRAM | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| Baseline | 1397.12 +/- 30.82 | 1395.63 +/- 1.35 | 43.02 +/- 0.02 | 16509 MiB | Selected |
| No graphs | 1400.85 +/- 9.81 | 1394.90 +/- 2.05 | 40.67 +/- 0.04 | 16461 MiB | Rejected: generation was 5.46 percent slower |
| Force cuBLAS | 1231.31 +/- 27.59 | 1229.60 +/- 0.64 | 42.91 +/- 0.04 | 16699 MiB | Rejected: prompt processing was 11.89 percent slower |

The selected and retained production build is `build-minipc-nvidia`, with CUDA graphs enabled and the default adaptive MMQ/cuBLAS selection. The no-graphs smoke test initially appeared faster for a 128-token prompt, but the five-repetition 512-token and 2048-token tests showed equivalent prompt speed and slower generation. The `build-minipc-nvidia-no-graphs` and `build-minipc-nvidia-force-cublas` directories were removed after this decision.

Runtime tuning confirmed the launcher defaults:

- Six CPU threads matched or exceeded 12 and 22 threads.
- Flash attention improved the 2048-token prompt test from 1335.13 to 1389.86 tok/s and slightly improved generation.
- A microbatch of 512 was faster than 128 or 256.
- Batch sizes 512, 1024, and 2048 were within 0.4 percent at microbatch 512. Keep 2048 for long prompts.

The benchmark telemetry reported a Gen4 x8 active PCIe link, about 390 W peak GPU power, and 66 C or lower peak temperature. Raw benchmark artifacts are stored outside the repository under `${XDG_STATE_HOME:-$HOME/.local/state}/llama.cpp/benchmarks/minipc-nvidia/`.

The selected launcher also passed a full server smoke test at context size 32768. The model loaded on `CUDA0`, `/health` returned `ok`, the Web UI returned HTTP 200, the seven explicitly configured tools were listed by `/tools`, and a deterministic chat request with thinking disabled returned `OK`. `ss` confirmed a listener only on `127.0.0.1:8080`, and the port closed after a clean shutdown.

The Intel Arc iGPU is not part of this pass. Evaluate it later in a separate Vulkan build rather than combining CUDA and Vulkan in the production binary.
