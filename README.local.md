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
- The Gemma 4 12B Q4 model fully offloads to the AMD integrated GPU.
- Vulkan device discovery, CLI inference, server inference, and benchmarking
  have been tested.
- The embedded Web UI and Gemma's native structured tool calling have been
  tested with the built-in llama-server tools.
- Gemma 4 multi-token prediction is enabled with the matching MTP sidecar.
- Vulkan substantially outperformed the tested HIP build on this machine.

Nothing else needs to be built for local chat, the HTTP API, the Web UI, basic
agent tools, or benchmarking. Rebuild only after updating llama.cpp or changing
the build configuration.

## Quick start

Start the server from anywhere:

```bash
./run_server.sh
```

Open `http://127.0.0.1:8080` in a browser. Stop the server with `Ctrl-C`.

The launcher defaults are:

- Binary: `build-vulkan-amd/bin/llama-server`
- Model: `$HOME/models/gemma-4-12B-qat/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf`
- MTP model: `mtp-gemma-4-12B-it.gguf` beside the main model
- Speculative draft window: up to 4 tokens
- Context size: 32768
- Server slots: 1
- Address: `127.0.0.1:8080`
- GPU: `Vulkan0`, with all model layers offloaded

Override configurable values for one run:

```bash
LLAMA_MODEL=/path/to/model.gguf \
LLAMA_MTP_MODEL=/path/to/mtp-model.gguf \
LLAMA_SPEC_DRAFT_N_MAX=4 \
LLAMA_PORT=8081 \
LLAMA_CTX_SIZE=16384 \
./run_server.sh
```

`LLAMA_SERVER_BIN` can select another llama-server build. The launcher keeps
the host fixed to loopback and deliberately does not expose a host override.
Set `LLAMA_ENABLE_MTP=0` to disable the drafter for comparison or to run a
model without a matching Gemma 4 assistant sidecar.

## Gemma 4 multi-token prediction

The launcher enables Gemma 4's multi-token prediction support through
speculative decoding. It passes these options to llama-server:

```text
--spec-type draft-mtp
--model-draft /path/to/mtp-gemma-4-12B-it.gguf
--device-draft Vulkan0
--gpu-layers-draft 99
--spec-draft-n-max 4
```

The default MTP path is derived from the main model directory, so selecting a
different `LLAMA_MODEL` also looks for `mtp-gemma-4-12B-it.gguf` in that
directory. Set `LLAMA_MTP_MODEL` when the sidecar has a different name or
location.

The sidecar's GGUF metadata identifies it as a 423M `gemma4-assistant` model
with four transformer blocks. The draft window is not constrained to four:
the assistant proposes draft tokens autoregressively and llama.cpp stops at
`LLAMA_SPEC_DRAFT_N_MAX`. Four is a conservative starting point. A larger
window offers more potential accepted tokens but wastes more draft and target
verification work when an early token is rejected.

MTP is an inference optimization, not a larger context or a change to model
quality. Draft tokens are checked by the main model before acceptance. The
speed benefit depends on acceptance rate and the overhead of running the
sidecar, so benchmark representative prompts before deciding whether to keep
it enabled.

### How Gemma 4 MTP differs from other drafters

A conventional `draft-simple` model is a separate, smaller language model. It
reads the accepted token sequence, predicts candidate tokens one at a time,
and needs a tokenizer and vocabulary compatible with the target. It can be
trained independently, but its predictions may diverge from the target and
reduce the acceptance rate.

Gemma 4's MTP assistant is target-specific rather than independent. It shares
the target's input embedding table and builds on the target's last-layer
activations. In llama.cpp, the Gemma 4 assistant also shares target KV memory.
That tighter coupling gives a small drafter better information about what the
target would predict, which should improve acceptance for its size. The
assistant still proposes tokens autoregressively; "multi-token prediction"
describes its role in producing a run of candidates for one parallel target
verification step, not an unchecked replacement for target generation.

Other supported target-specific approaches make different tradeoffs:

- `draft-eagle3` uses a small one-layer autoregressive transformer that reads
  selected target hidden states.
- `draft-dflash` uses several transformer layers and block diffusion to emit a
  whole candidate block in one forward pass.
- `ngram-*` methods use repeated token patterns rather than another neural
  model, so they need no sidecar but work best on repetitive text such as code.

Google's Gemma 4 MTP overview is at
<https://ai.google.dev/gemma/docs/mtp/overview>. The llama.cpp implementation
overview is in [docs/speculative.md](docs/speculative.md).

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

The tested Gemma GGUF contains a native tool-aware chat template. A chat
completion test produced a valid structured `get_datetime` tool call, so no
chat-template override is needed for this model.

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

Vulkan was substantially faster than the HIP/ROCm backend for the available
12B Gemma 4 Q4 model. Vulkan also handled the integrated GPU's shared system
memory without a special unified-memory environment variable.

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
memory, enough to fully offload the 6.7 GB test model.

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
  --model "$HOME/models/gemma-4-12B-qat/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf" \
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
  --model "$HOME/models/gemma-4-12B-qat/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf" \
  --n-prompt 512 \
  --n-gen 64 \
  --repetitions 3 \
  --n-gpu-layers 99 \
  --device Vulkan0 \
  --flash-attn auto \
  --threads 8
```

Measured Vulkan baseline:

- Prompt processing: 118.7 tokens/second
- Token generation: 7.63 tokens/second

These are comparison baselines, not guarantees. Power mode, temperature,
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

The same model and benchmark settings produced:

- Vulkan: 118.7 prompt tokens/second, 7.63 generation tokens/second
- HIP: 80.4 prompt tokens/second, 5.29 generation tokens/second

Vulkan was about 48 percent faster for prompt processing and 44 percent faster
for generation. Enabling `GGML_HIP_ROCWMMA_FATTN=ON` failed compilation because
the installed rocWMMA 7.1 headers reported `Unsupported architecture` for
`gfx1152`. Standard HIP compiled after disabling that option.

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
git add README.local.md run_server.sh
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

- Vulkan with Mesa RADV is the preferred backend for the Radeon 860M and this
  model; it was faster than the tested ROCm 7.1 HIP build.
- Integrated GPU memory can exceed the firmware's nominal VRAM aperture. The
  6.7 GB model fully offloaded even though firmware reported 4 GiB VRAM.
- A separate HIP or CPU build is not required for the current workflow.
- The existing Vulkan build already contains the server, CLI, benchmark, and a
  working embedded Web UI. No further target is needed for built-in tools.
- The current Gemma model's GGUF metadata includes a native tool-aware chat
  template, and it emitted a valid structured tool call in a live test.
- Built-in tools are convenient for a trusted local Web UI, but they are not a
  sandbox. Browser approval does not protect the underlying `/tools` endpoint.
- `--tools` with an explicit list is preferable to `--agent` for controlled
  local use.
- The launcher uses one server slot so the full 32768-token context is assigned
  to the active conversation instead of being divided among parallel slots.
- Gemma 4 MTP uses the matching 423M `gemma4-assistant` sidecar on Vulkan0 and
  defaults to drafting up to four tokens per speculative step.
- A live MTP smoke test drafted 44 tokens, accepted 36 (81.8 percent), and
  generated 48 tokens at 17.5 tokens/s. This confirms operation but is not a
  controlled comparison with the earlier non-MTP benchmark.
- `/tools` is an internal Web UI interface. External clients should own their
  command policy, approval, filesystem boundaries, and tool execution loop.
- Keep the official mirror branch free of local commits. Rebase the personal
  branch onto it and use `--force-with-lease` when updating the personal fork.
