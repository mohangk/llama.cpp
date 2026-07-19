# Gemma 4 local setup

This document records the model-specific configuration and findings for the
Gemma 4 12B setup used by `run_server.sh`. General AMD build, server-tool,
security, and repository workflow notes remain in `README.local.md`.

## Current model

- Target: `$HOME/models/gemma-4-12B-qat/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf`
- MTP sidecar: `mtp-gemma-4-12B-it.gguf` in the target directory
- Target size: about 6.7 GB
- Context: 32768 tokens
- Parallel slots: 1
- Device: `Vulkan0`, with target and drafter layers fully offloaded
- Server address: `127.0.0.1:8080`

The GGUF contains a native tool-aware chat template. A live chat-completion
test produced a valid structured `get_datetime` tool call, so this model does
not need a chat-template override.

## Launcher

Start the server from the repository root or any other directory:

```bash
./run_server.sh
```

Open `http://127.0.0.1:8080` in a browser and stop the server with `Ctrl-C`.

The launcher defaults are:

- Binary: `build-vulkan-amd/bin/llama-server`
- Target and sidecar paths listed above
- Speculative draft window: up to three tokens
- Context size: 32768
- Server slots: 1
- GPU: `Vulkan0`, with all model layers offloaded
- Host: loopback only
- Built-in tools: the explicit allowlist documented in `README.local.md`

Override configurable values for one run:

```bash
LLAMA_MODEL=/path/to/model.gguf \
LLAMA_MTP_MODEL=/path/to/mtp-model.gguf \
LLAMA_SPEC_DRAFT_N_MAX=3 \
LLAMA_PORT=8081 \
LLAMA_CTX_SIZE=16384 \
./run_server.sh
```

`LLAMA_SERVER_BIN` can select another server build. The launcher deliberately
keeps the host fixed to loopback. Set `LLAMA_ENABLE_MTP=0` to compare baseline
generation or run a model without the matching Gemma 4 assistant sidecar.

## Multi-token prediction

The launcher enables Gemma 4 multi-token prediction through speculative
decoding with:

```text
--spec-type draft-mtp
--model-draft /path/to/mtp-gemma-4-12B-it.gguf
--device-draft Vulkan0
--gpu-layers-draft 99
--spec-draft-n-max 3
```

The default MTP path is derived from the main model directory. Selecting a
different `LLAMA_MODEL` therefore looks for `mtp-gemma-4-12B-it.gguf` beside
that target unless `LLAMA_MTP_MODEL` is set explicitly.

The sidecar metadata identifies it as a 423M `gemma4-assistant` model with four
transformer blocks. The assistant can generate more than three tokens; three
is the launcher's configured maximum for one speculative step. A larger window
offers more potential accepted tokens but wastes more draft and target
verification work after an early rejection.

MTP is an inference optimization, not a larger context or a model-quality
change. The target verifies every candidate. Speed therefore depends on both
acceptance rate and drafter overhead and must be measured on representative
prompts.

### How the Gemma assistant differs from other drafters

A conventional `draft-simple` model is a separate, smaller language model. It
reads the accepted token sequence, predicts candidates autoregressively, and
needs a tokenizer and vocabulary compatible with the target. It can be trained
independently, but its predictions may diverge from the target and reduce
acceptance.

Gemma 4's MTP assistant is target-specific. It shares the target input
embedding table, uses the target last-layer activations, and shares target KV
memory in llama.cpp. This gives the small assistant better information about
the target prediction. It still proposes tokens autoregressively;
"multi-token prediction" means it supplies a candidate run for one parallel
target verification step.

Other supported target-specific approaches make different tradeoffs:

- `draft-eagle3` uses a small one-layer autoregressive transformer that reads
  selected target hidden states.
- `draft-dflash` uses several transformer layers and block diffusion to emit a
  candidate block in one forward pass.
- `ngram-*` methods use repeated token patterns instead of another neural
  model and work best on repetitive text such as code.

Google's overview is at
<https://ai.google.dev/gemma/docs/mtp/overview>. The llama.cpp implementation
overview is in [speculative decoding](../docs/speculative.md).

## CLI smoke test

```bash
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json

./build-vulkan-amd/bin/llama-cli \
  --model "$HOME/models/gemma-4-12B-qat/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf" \
  --device Vulkan0 \
  --gpu-layers 99 \
  --flash-attn auto \
  --ctx-size 4096
```

KV-cache offload and memory mapping are enabled by default and worked well.
Do not add `--no-kv-offload` when maximizing GPU use.

## Benchmark

Reproduce the original Vulkan benchmark with:

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

Measured results:

| Backend | Prompt tok/s | Generation tok/s |
| --- | ---: | ---: |
| Vulkan | 118.7 | 7.63 |
| HIP | 80.4 | 5.29 |

Vulkan was about 48 percent faster for prompt processing and 44 percent faster
for generation in this test. Power mode, temperature, background work,
context, quantization, and driver versions affect the result.

The MTP live smoke test drafted 44 tokens, accepted 36 tokens (81.8 percent),
and generated 48 target tokens at 17.5 tokens/s. It confirmed that the sidecar
worked but was not a controlled comparison against the earlier llama-bench
baseline. The controlled evaluation below supersedes that smoke result for
configuration decisions.

## Controlled local evaluation

This evaluation ran on 2026-07-19 with llama.cpp version 10068 at commit
`571d0d540`, the Vulkan RADV backend, a 32768-token context, one parallel slot,
all target and draft layers on `Vulkan0`, and fit disabled.

### Artifact verification

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `gemma-4-12B-it-qat-UD-Q4_K_XL.gguf` | 6716356800 | `90fd44e29e0d7cffeb0fd00dc73cfdab9ed0b0e95306ecf7821ea634c940c370` |
| `mtp-gemma-4-12B-it.gguf` | 253708800 | `fcb35dea42c71333db904cee11baac525c9ef872818ee3753f6cb156f3c6f4f6` |

The target metadata reports architecture `gemma4`, 12B size label, 48 blocks,
3840 embedding width, 262144 native context, and an embedded chat template.
The assistant reports architecture `gemma4-assistant`, 423M size label, four
blocks, 1024 internal embedding width, 3840 output width, and matching
tokenizer IDs.

### Method

The run followed [the local evaluation protocol](local-evals.md): one warmup,
then the four fixed prompts three times each at temperature zero, seed 42, and
a 64-token response cap. Each configuration generated 765 measured target
tokens. Baseline and draft windows two and three form the standard matrix;
window four was added because it was the `run_server.sh` default when the
evaluation began.

### Performance

| Configuration | Prompt tok/s | Generation tok/s | Median gen tok/s | Drafted | Accepted | Acceptance |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline | 42.79 | 10.26 | 10.23 | 0 | 0 | N/A |
| MTP, max 2 | 42.67 | 19.29 | 19.32 | 546 | 477 | 87.4% |
| MTP, max 3 | 42.98 | 19.41 | 20.54 | 655 | 532 | 81.2% |
| MTP, max 4 | 43.33 | 18.86 | 21.20 | 746 | 561 | 75.2% |

Window three improved aggregate generation by 89.1 percent and median
per-request generation by 100.7 percent over baseline. Window four has a high
median because it is very fast on predictable prompts, but its aggregate rate
is 2.8 percent lower than window three. On the factual prompt, window-four
acceptance fell as low as 44.9 percent and generation fell to 12.58 tok/s.

Window two is only 0.6 percent slower than window three in aggregate and has
higher acceptance. Window three is the best result for this mixed prompt set;
window two is the conservative choice for less predictable workloads.

### Memory observations

These `amd-smi` samples were taken immediately after each measured run. They
are system-wide observations that include the desktop, not per-process peaks.

| Configuration | Visible VRAM used | GTT used | Total observed | Temperature |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 4034 MiB | 6065 MiB | 10099 MiB | 56 C |
| MTP, max 2 | 3992 MiB | 6517 MiB | 10509 MiB | 48 C |
| MTP, max 3 | 3967 MiB | 6547 MiB | 10514 MiB | 50 C |
| MTP, max 4 | 3927 MiB | 6596 MiB | 10523 MiB | 51 C |

All configurations retained the requested context and offload settings. No
fit reduction, OOM recovery, or server crash occurred. The server warned that
the template does not support preserving reasoning, so `--reasoning-preserve`
had no effect.

### Functional checks

| Check | Result | Notes |
| --- | --- | --- |
| Text generation | Pass | All four outputs were coherent; the 64-token benchmark cap intentionally truncated longer code and arithmetic answers. |
| Strict prompt-only JSON | Fail | All three measured responses wrapped the correct object in Markdown fences, so raw content did not parse as JSON. |
| Constrained JSON | Pass | `response_format: {"type":"json_object"}` produced valid JSON with the required keys and three-string feature array. |
| Arithmetic | Pass | A 128-token functional request completed the calculation `25 - 10 = 15`. |
| Structured tool call | Pass | Returned `get_weather` with valid arguments `{"city":"Singapore"}` and finish reason `tool_calls`. |
| Multi-turn context | Pass | Recalled `Zephyr-19` exactly and remained healthy. |
| Vision | Not run | No matching vision projector is present in the local Gemma model directory. |

The strict JSON failure means this configuration does not meet every protocol
criterion through prompting alone. API clients that require machine-readable
JSON should request a JSON response format or apply an explicit grammar rather
than trusting the prompt.

### Comparison with Qwen 3.6 27B

Under the same 12-request server protocol, Gemma baseline was 2.66 times as
fast as Qwen baseline (10.26 versus 3.86 tok/s). Gemma MTP window three was
2.72 times as fast as Qwen MTP window three (19.41 versus 7.15 tok/s). Gemma
MTP used about 10.3 GiB of observed system graphics memory versus about 24.4
GiB for Qwen MTP.

Qwen passed strict prompt-only JSON, vision, tool-call, and multi-turn checks.
Gemma was faster and used less memory, but strict JSON required response
constraints and vision was not configured.

### Decision

Use a maximum draft window of three for the measured mixed workload. The
launcher now defaults to three based on this result. Set
`LLAMA_SPEC_DRAFT_N_MAX` explicitly to reproduce another measured window.

## Verified findings

- The target fully offloaded through Vulkan despite exceeding the firmware's
  nominal 4 GiB VRAM aperture because the integrated GPU uses shared memory.
- The target chat template emitted a structured tool call without an override.
- Target and MTP sidecar both loaded on `Vulkan0`.
- A separate HIP or CPU build is not required for this workflow.
- The existing Vulkan build supplies the CLI, benchmark, server, and embedded
  Web UI needed by this setup.
