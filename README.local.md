# Local llama.cpp operating notes

This file is the operating manual for this clone. It records the local build,
server, tool-access, security, performance, and repository-management choices
that were verified on this laptop. It is intentionally separate from the
upstream `README.md` and is intended to be tracked only in the personal fork.

## Current state

The local Vulkan build is complete and usable:

- `build-vulkan-amd/bin/llama-cli`
- `build-vulkan-amd/bin/llama-server`
- `build-vulkan-amd/bin/llama-bench`
- Release and native CPU optimization are enabled.
- Vulkan device discovery, CLI inference, server inference, and benchmarking
  have been tested.
- The embedded Web UI and built-in llama-server tools have been tested.
- The current launcher targets the validated
  [Gemma 4 setup](doc-local/gemma4.md).
- Qwen 3.6 27B text, vision, tool calling, and MTP have been validated; see
  [the local Qwen MTP results](doc-local/qwen36-mtp-plan.md).
- Repeatable model and backend comparisons use the
  [local evaluation protocol](doc-local/local-evals.md).
- Vulkan substantially outperformed the tested HIP build on this machine.

Nothing else needs to be built for local chat, the HTTP API, the Web UI, basic
agent tools, or benchmarking. Rebuild only after updating llama.cpp or changing
the build configuration.

## Quick start

The current launcher starts the local Gemma 4 configuration:

```bash
./run_server.sh
```

Open `http://127.0.0.1:8080` in a browser. Stop the server with `Ctrl-C`.

Model paths, environment overrides, MTP behavior, and validated benchmark
results are recorded in [the Gemma 4 document](doc-local/gemma4.md). The Qwen
experiment currently uses its documented direct server command rather than
this Gemma-specific launcher.

## TODO

- Create a Qwen 3.6 server launcher using the validated target, vision
  projector, MTP sidecar, and three-token draft window. Decide whether this
  should be a separate script or a generalized model-selecting replacement for
  `run_server.sh`, while preserving loopback binding and the explicit tool
  allowlist.

Monitor the AMD GPU from another terminal:

```bash
amd-smi metric -g 0 -u -c -t -p -w 1
```

## Server tools

This checkout contains experimental built-in tools in llama-server. The
launcher enables these tools explicitly:

- `read_file`: read a file or selected line range
- `file_glob_search`: find files with a glob pattern
- `grep_search`: search file contents
- `exec_shell_command`: execute a command through `sh -c`
- `write_file`: create or overwrite a file
- `edit_file`: replace text in a file
- `get_datetime`: return the server's date and time

The explicit list is intentional. `--agent` is not used because it also
enables the MCP CORS proxy and implicitly enables every built-in tool. An
explicit list also prevents future llama.cpp tools from becoming available
without review.

### Using tools in the Web UI

1. Start `./run_server.sh` and open the Web UI.
2. Ask the model to perform a concrete action, such as reporting the current
   time or reading a known file.
3. Inspect the proposed tool and its arguments.
4. Select `Allow once` only when the call is expected.
5. Deny unexpected calls, especially commands or writes suggested by content
   the model just read.

The UI also offers persistent approval choices. Do not use them for this
configuration. If one is selected accidentally, revoke it in the Chat Tools
settings. Permissions are stored in browser local storage, not enforced by the
server.

### Tool implementation limits

The limits observed in this checkout are:

- `read_file` returns at most 16 KiB unless a line range narrows the request.
- Shell output is limited to 16 KiB.
- Shell timeout is capped at 60 seconds.
- File searches are bounded to 100 results.
- Paths are passed to the host filesystem without a configured allowed root.

`GET /tools` lists the enabled built-ins and `POST /tools` invokes one. These
endpoints are intended for llama-server's Web UI and are explicitly documented
as internal and subject to change. A separate application should use the
OpenAI-compatible chat API and implement its own tool loop instead of depending
on `/tools`.

Relevant upstream material:

- [Server usage and built-in tools](tools/server/README.md)
- [Server development and endpoint scope](tools/server/README-dev.md)
- [Initial built-in tool implementation](https://github.com/ggml-org/llama.cpp/pull/20898)
- [Web UI agent loop and approvals](https://github.com/ggml-org/llama.cpp/pull/21237)

## Security model

This is a high-trust local configuration. The enabled tools run with the same
permissions as the user who starts llama-server.

- File reads, writes, and edits are not confined to this repository.
- Shell commands run through `sh -c` and inherit the server's environment,
  current user, `PATH`, network access, and filesystem access.
- The launcher changes to the repository root before starting the server, so
  relative shell paths start here. This is a convenience, not a sandbox.
- A model can propose harmful calls because of a user prompt, hallucination, or
  prompt injection in a file or command output.
- CORS restrictions do not provide authentication.

The server binds only to `127.0.0.1` and has no API key. This accepts the risk
that another process running on the laptop can call the API. More importantly,
Web UI approval is client-side only: a direct local `POST /tools` request does
not display an approval prompt. Do not expose port 8080 through a LAN binding,
reverse proxy, tunnel, container port publication, or firewall rule.

Before opening files from an untrusted project, consider using a separate Unix
account, container, or virtual machine. The current launcher intentionally does
not claim to provide a filesystem or command sandbox.

## Verification checklist

After changing the launcher, model, build, or llama.cpp revision:

```bash
bash -n run_server.sh
./build-vulkan-amd/bin/llama-server --help | grep -E -- '--tools|--ui|--jinja'
./run_server.sh
```

With the server running:

```bash
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/tools
curl --fail --compressed --output /dev/null http://127.0.0.1:8080/
```

The root response is gzip-compressed. Use `curl --compressed`; a client without
gzip support can report an error even when the UI works in a browser.

Use `ss -ltnp` to confirm that the process listens only on `127.0.0.1:8080`.
Then test these calls through the Web UI with `Allow once`:

- Return the current date and time.
- Read a known non-sensitive file.
- Run `pwd` and confirm it returns the repository root.
- Create, edit, read, and delete a disposable file.

## AMD GPU build and performance

### Recommendation

Use the Vulkan backend with Mesa RADV on this laptop.

Vulkan was substantially faster than the tested HIP/ROCm backend. Vulkan also
handled the integrated GPU's shared system memory without a special
unified-memory environment variable. The model-specific comparison is in the
[Gemma 4 benchmark](doc-local/gemma4.md#benchmark).

### System context

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

Although the firmware reports 4 GiB VRAM, this is an integrated GPU with
unified memory. llama.cpp's Vulkan backend reported about 34 GiB usable device
memory and fully offloaded models larger than the dedicated VRAM aperture.

Detected Vulkan capabilities included FP16 and integer dot products, KHR
cooperative matrices, 64 KiB shared memory, and UMA support.

### Fedora dependencies

```bash
sudo dnf install \
  gcc-c++ cmake make ccache \
  vulkan-loader-devel vulkan-tools mesa-vulkan-drivers \
  glslc spirv-headers-devel
```

The backend requires the Vulkan loader and headers, Mesa RADV, `glslc`, and
SPIR-V headers including `spirv/unified1/spirv.hpp`.

Verify the driver:

```bash
vulkaninfo --summary
```

The expected device is:

```text
AMD Radeon 860M Graphics (RADV KRACKAN1)
```

Mesa also installs software and unrelated ICD files. The launcher restricts
the Vulkan loader to RADV with:

```bash
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json
```

This is optional for llama.cpp on this machine, but makes selection
deterministic and avoids unrelated Vulkan loader warnings.

### Recommended build

Run from the repository root:

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

Important choices:

- `CMAKE_BUILD_TYPE=Release` enables optimized compilation.
- `GGML_VULKAN=ON` builds the Vulkan backend.
- `GGML_HIP=OFF` avoids loading a second GPU backend.
- `GGML_NATIVE=ON` uses `-march=native` for CPU fallback work.
- `LLAMA_BUILD_TESTS=OFF` avoids unnecessary test binaries.
- `LLAMA_BUILD_SERVER=ON` is required by this checkout to generate
  `llama-cli`, because the CLI reuses server implementation code.
- `LLAMA_BUILD_UI=OFF` records that a fresh UI build was not requested. This
  checkout still supplied usable embedded UI assets to the tested server.

Leave Vulkan validation, result checking, and shader debugging disabled for a
performance build. The first build generates the shader set; later builds reuse
generated output and ccache.

### Verify the build

```bash
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json

./build-vulkan-amd/bin/llama-cli --version
./build-vulkan-amd/bin/llama-cli --list-devices
```

Expected output includes:

```text
Vulkan0: AMD Radeon 860M Graphics (RADV KRACKAN1)
```

If `Vulkan0` is absent, check `vulkaninfo --summary`, the RADV ICD path, and
permissions on `/dev/dri/renderD128` before rebuilding.

### Run the CLI

```bash
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json

./build-vulkan-amd/bin/llama-cli \
  --model /path/to/model.gguf \
  --device Vulkan0 \
  --gpu-layers 99 \
  --flash-attn auto \
  --ctx-size 4096
```

`--gpu-layers 99` requests full offload for models with fewer than 99 layers.
KV-cache offload and memory mapping are enabled by default and worked well. Do
not add `--no-kv-offload` when maximizing GPU use. Larger contexts increase KV
cache memory, so monitor memory and performance rather than assuming a single
ideal maximum.

### Reproduce the Vulkan benchmark

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

Use [the local evaluation protocol](doc-local/local-evals.md) for comparable
model and speculative-decoding measurements. Power mode, temperature,
background work, context size, quantization, and driver updates affect results.
The APU shares thermal and power limits between CPU and GPU.

### Vulkan versus HIP

ROCm 7.1 detected the GPU as `gfx1152`. The targeted HIP benchmark build in
`build-hip-amd` used:

```text
GGML_HIP=ON
GPU_TARGETS=gfx1152
GGML_NATIVE=ON
GGML_HIP_ROCWMMA_FATTN=OFF
```

HIP required this variable to expose system memory for a model larger than the
dedicated VRAM aperture:

```bash
export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1
```

The controlled Vulkan and HIP results are in the
[Gemma 4 benchmark](doc-local/gemma4.md#benchmark). Enabling
`GGML_HIP_ROCWMMA_FATTN=ON` failed compilation because the installed rocWMMA
7.1 headers reported `Unsupported architecture` for `gfx1152`. Standard HIP
compiled after disabling that option.

Keep the HIP build only for future comparisons after ROCm or llama.cpp changes.

## Build maintenance

After updating llama.cpp, configure and build the same directory again:

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

Use a new build directory if CMake says its cache was created elsewhere. Do not
copy `CMakeCache.txt` between build directories.

Build extra targets only when needed:

- `llama-quantize`: convert an existing GGUF to another quantization
- `llama-perplexity`: evaluate model perplexity
- `llama-embedding`: generate embeddings
- `llama-imatrix`: produce an importance matrix for quantization
- `llama-gguf-split`: split or combine GGUF files
- `llama`: build the newer unified application target

Example:

```bash
cmake --build build-vulkan-amd --target llama-quantize -j 16
```

Building every target adds compile time and disk use without improving normal
inference performance.

## Personal fork workflow

The goal is to preserve `README.local.md` and `run_server.sh` in a personal
public fork without treating them as an upstream llama.cpp contribution. No
pull request is planned.

The intended topology is:

- Remote `upstream`: `git@github.com:ggml-org/llama.cpp.git`
- Remote `origin`: `git@github.com:mohangk/llama.cpp.git`
- Branch `upstream-sync`: clean mirror of `upstream/master`
- Branch `master`: personal changes rebased on `upstream-sync`

All GitHub forks of a public repository are public. Do not add API keys,
credentials, private host details, model files, or generated output to these
commits.

### Establish the fork

First create `mohangk/llama.cpp` with GitHub's Fork action. Then configure this
clone:

```bash
git remote rename origin upstream
git remote add origin git@github.com:mohangk/llama.cpp.git
git fetch origin
git branch upstream-sync upstream/master
git branch --set-upstream-to=origin/master master
git remote -v
git branch -vv
```

Review and commit only the local workflow files:

```bash
git status --short
git add README.local.md run_server.sh doc-local
git diff --cached
git commit
```

Write the commit message personally and make sure the changes are understood.
If an AI assistant is explicitly authorized to run the commit, its assistance
must be disclosed with an `Assisted-by:` trailer. The repository instructions
prohibit an agent from pushing or creating a pull request, so run the initial
push personally:

```bash
git push origin master
git push origin upstream-sync
```

### Synchronize with upstream

Start with a clean worktree, then update the mirror and rebase the personal
branch:

```bash
git fetch upstream
git switch upstream-sync
git merge --ff-only upstream/master
git push origin upstream-sync

git switch master
git rebase upstream-sync
```

Rebuild and repeat the verification checklist after the rebase. If everything
works, update the personal fork manually:

```bash
git push --force-with-lease origin master
```

`--force-with-lease` is required because rebase changes commit IDs. It refuses
to overwrite remote work that was not present in the last local fetch. Resolve
rebase conflicts carefully rather than discarding upstream or local changes.

## Session learnings

- Vulkan with Mesa RADV is the preferred backend for the Radeon 860M; it was
  faster than the tested ROCm 7.1 HIP build.
- Integrated GPU memory can exceed the firmware's nominal VRAM aperture. The
  tested models can use shared system memory beyond the reported 4 GiB VRAM.
- A separate HIP or CPU build is not required for the current workflow.
- The existing Vulkan build already contains the server, CLI, benchmark, and a
  working embedded Web UI. No further target is needed for built-in tools.
- Built-in tools are convenient for a trusted local Web UI, but they are not a
  sandbox. Browser approval does not protect the underlying `/tools` endpoint.
- `--tools` with an explicit list is preferable to `--agent` for controlled
  local use.
- The launcher uses one server slot so the full 32768-token context is assigned
  to the active conversation instead of being divided among parallel slots.
- `/tools` is an internal Web UI interface. External clients should own their
  command policy, approval, filesystem boundaries, and tool execution loop.
- Keep the official mirror branch free of local commits. Rebase the personal
  branch onto it and use `--force-with-lease` when updating the personal fork.
