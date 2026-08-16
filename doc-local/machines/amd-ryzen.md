# AMD Ryzen laptop profile

This profile preserves the validated Vulkan configuration for the AMD Ryzen AI 7 PRO 350 laptop. Vulkan with Mesa RADV outperformed the tested HIP build on this machine.

## Hardware snapshot

The system inspected on 2026-07-19 had:

- OS: Fedora Linux 44 Workstation
- Kernel: Linux 7.1.3-201.fc44.x86_64
- CPU: AMD Ryzen AI 7 PRO 350, 8 cores and 16 threads
- CPU features: AVX2, AVX-512, AVX-VNNI, AVX512-VNNI, F16C, and FMA
- GPU: AMD Radeon 860M integrated graphics
- GPU architecture: `gfx1152`
- GPU compute units: 8
- Kernel driver: `amdgpu`
- Vulkan driver: Mesa RADV 26.1.4
- Vulkan API: 1.4
- System memory: 58 GiB
- Firmware-reported VRAM: 4096 MiB
- Repository revision: `571d0d540`, build 10068

Although firmware reports 4 GiB VRAM, this is an integrated GPU with unified memory. llama.cpp Vulkan reported about 34 GiB usable device memory and fully offloaded models larger than the dedicated VRAM aperture.

Detected Vulkan capabilities included FP16, integer dot products, KHR cooperative matrices, 64 KiB shared memory, and UMA support.

## Dependencies

```bash
sudo dnf install \
  gcc-c++ cmake make ccache \
  vulkan-loader-devel vulkan-tools mesa-vulkan-drivers \
  glslc spirv-headers-devel
```

Verify the expected device:

```bash
vulkaninfo --summary
```

Expected device:

```text
AMD Radeon 860M Graphics (RADV KRACKAN1)
```

The launcher restricts Vulkan to the RADV ICD:

```bash
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json
```

## Recommended build

Use the machine-specific build script:

```bash
./local-scripts/amd-ryzen-build.sh
```

It verifies the RADV ICD and expected Radeon 860M device before configuring this equivalent build:

```bash
cmake -S . -B build-vulkan-amd \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON \
  -DGGML_HIP=OFF \
  -DGGML_NATIVE=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_UI=OFF

cmake --build build-vulkan-amd \
  --target llama-cli llama-bench llama-server \
  -j 16
```

Release and native CPU optimization are enabled. Tests, HIP, and unnecessary targets are disabled. Vulkan validation, result checking, and shader debugging remain disabled for performance builds.

The first build generates shaders. Later builds reuse generated output and ccache. Set `LLAMA_BUILD_JOBS` to override 16 parallel build jobs or `LLAMA_VULKAN_ICD` to intentionally select another ICD path.

## Verify the build

```bash
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json

./build-vulkan-amd/bin/llama-cli --version
./build-vulkan-amd/bin/llama-cli --list-devices
```

Expected output includes:

```text
Vulkan0: AMD Radeon 860M Graphics (RADV KRACKAN1)
```

If `Vulkan0` is absent, check `vulkaninfo --summary`, the RADV ICD path, and permissions on `/dev/dri/renderD128` before rebuilding.

## Run the server

The preserved Gemma 4 launcher is:

```bash
./local-scripts/amd-ryzen-run.sh
```

The launcher uses `Vulkan0`, full target and drafter offload, one server slot, a 32768-token context, loopback binding, and the explicit built-in tool allowlist. Model and MTP behavior are documented in [the Gemma 4 setup](../gemma4.md).

## Reproduce the benchmark

```bash
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json

./build-vulkan-amd/bin/llama-bench \
  --model /path/to/model.gguf \
  --n-prompt 512 \
  --n-gen 64 \
  --repetitions 3 \
  --n-gpu-layers 99 \
  --device Vulkan0 \
  --flash-attn auto \
  --threads 8
```

Use the [local evaluation protocol](../local-evals.md) for comparable model and speculative-decoding measurements. Power mode, temperature, background work, context size, quantization, and driver updates affect results. The APU shares thermal and power limits between CPU and GPU.

## Vulkan versus HIP

The targeted HIP comparison used:

```text
GGML_HIP=ON
GPU_TARGETS=gfx1152
GGML_NATIVE=ON
GGML_HIP_ROCWMMA_FATTN=OFF
```

HIP required `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` to expose system memory for a model larger than the dedicated VRAM aperture. Vulkan did not require this variable.

The controlled results are in the [Gemma 4 benchmark](../gemma4.md#benchmark). Vulkan delivered about 118.7 prompt tok/s and 7.63 generation tok/s for that test, approximately 48 percent faster in prompt processing and 44 percent faster in generation than HIP.

Enabling `GGML_HIP_ROCWMMA_FATTN=ON` failed because ROCm 7.1 rocWMMA headers reported `Unsupported architecture` for `gfx1152`. Keep the HIP build only for comparisons after ROCm or llama.cpp changes.

## Maintenance

Re-run the same configure and build commands after updating llama.cpp. Do not copy `CMakeCache.txt` between directories.

Build extra targets only when needed:

- `llama-quantize`: convert an existing GGUF to another quantization
- `llama-perplexity`: evaluate model perplexity
- `llama-embedding`: generate embeddings
- `llama-imatrix`: produce an importance matrix for quantization
- `llama-gguf-split`: split or combine GGUF files
- `llama`: build the unified application target

Monitor the GPU with:

```bash
amd-smi metric -g 0 -u -c -t -p -w 1
```

The AMD results apply only to this laptop and must not be used to choose the mini PC or future Mac profile.
