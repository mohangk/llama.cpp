# Qwen 3.6 27B MTP experiment

This document records the local Qwen 3.6 27B Multi-Token Prediction (MTP)
experiment on the AMD Radeon 860M Vulkan setup. The initial experiment is
deliberately separate from `run_server.sh`; the working Gemma 4 launcher stays
unchanged until Qwen has passed functional and performance checks.

## Goals

- Verify a publisher-matched Qwen 3.6 target and MTP sidecar with llama.cpp.
- Compare baseline generation with MTP draft windows of two and three tokens.
- Confirm text, vision, multi-turn, and structured tool-call behavior.
- Record enough detail to repeat the experiment after llama.cpp or driver
  updates.

## Environment

- Backend: Vulkan with Mesa RADV
- Device: `Vulkan0`, AMD Radeon 860M Graphics
- llama.cpp build: `build-vulkan-amd/bin/llama-server`
- llama.cpp version at start: `10068 (571d0d540)`
- Context: 32768 tokens
- Parallel slots: 1
- Test address: `127.0.0.1:8094`

## Model artifacts

All files come from
[`ggml-org/Qwen3.6-27B-GGUF`](https://huggingface.co/ggml-org/Qwen3.6-27B-GGUF)
at revision `8a7ee08e8b9bfb857107ecc25a5599d2f38b76f8` and are stored in
`$HOME/models/qwen3.6-27B/`.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `Qwen3.6-27B-Q4_K_M.gguf` | 19095766304 | `65b753ea835627f7b511143c6ceb976525c7f21f5df8c664bc0a9c23d1c49921` |
| `mtp-Qwen3.6-27B-Q4_0.gguf` | 1680270560 | `3d593f9e2788d59bb30d6024706b1efd5219fea466b6397c46159e3540937173` |
| `mmproj-Qwen3.6-27B-Q8_0.gguf` | 629247104 | `dd184a692287f0d7e8fa56c8744df20c46667818efc04e6d48996d18d9521a4e` |

Downloads use `hf download` with the pinned revision. Hugging Face writes
temporary `.incomplete` files and materializes the final names when each
transfer completes. Verify the published SHA-256 values separately before
loading the files.

## Server configurations

Every run uses the same target, projector, device, context, and sampling
configuration. Only speculative decoding changes.

Common options:

```text
--model $HOME/models/qwen3.6-27B/Qwen3.6-27B-Q4_K_M.gguf
--mmproj $HOME/models/qwen3.6-27B/mmproj-Qwen3.6-27B-Q8_0.gguf
--device Vulkan0
--gpu-layers 99
--flash-attn auto
--fit off
--ctx-size 32768
--parallel 1
--jinja
--reasoning auto
--reasoning-preserve
--no-ui
--host 127.0.0.1
--port 8094
```

MTP runs additionally use:

```text
--spec-type draft-mtp
--model-draft $HOME/models/qwen3.6-27B/mtp-Qwen3.6-27B-Q4_0.gguf
--device-draft Vulkan0
--gpu-layers-draft 99
--spec-draft-n-max 2 or 3
```

## Test method

1. Verify all hashes and inspect GGUF metadata.
2. Start the baseline server and confirm `/health` and `/v1/models`.
3. Run one warmup request, followed by three measured repetitions of the text
   prompt set at temperature zero and a fixed seed.
4. Repeat with MTP draft windows of two and three tokens.
5. Record prompt speed, generation speed, draft count, accepted count,
   acceptance rate, and peak GPU memory.
6. Test a typed `image_url` request, an OpenAI-compatible tool definition, and
   a short multi-turn exchange with the best configuration.
7. Stop every temporary server after its measurements.

The text prompt set covers code generation, factual explanation, structured
JSON, and reasoning. Exact byte-for-byte output is not required because MTP
can change batch-level floating-point numerics. Semantic correctness and valid
structured output are required.

## Acceptance criteria

- Target, projector, and drafter load without compatibility errors.
- The configured 32768-token context is retained and all requested layers are
  offloaded without an out-of-memory failure.
- Aggregate MTP draft acceptance is at least 50 percent.
- At least one MTP window improves median generation speed by 15 percent or
  more over baseline.
- Vision produces a correct description without a crash.
- Tool calling produces a structurally valid tool call.
- Multi-turn context reuse does not corrupt output.

If the Q4_0 sidecar has less than 50 percent acceptance, test the official
`mtp-Qwen3.6-27B-Q8_0.gguf` sidecar next. Its expected size is 3164005600
bytes and its SHA-256 is
`ad3862cef3dc6a3eaa0525a5b9b225f1c9c45b15956a8314a30cfaa0344a1e08`.

## Results

### Artifact verification

All three files matched the byte sizes and SHA-256 values in the table above.
Metadata inspection also confirmed:

- Target: `qwen35`, 27B, 64 blocks, 5120 embedding width, 262144 native
  context, embedded chat template present.
- Drafter: `qwen35`, 3.0B size label, 65 blocks, 5120 embedding width, one
  next-token-prediction layer, matching tokenizer IDs.
- Projector: `clip` with vision encoder enabled and projector type
  `qwen3vl_merger`.

The official Q4_0 drafter exceeded the acceptance threshold, so the Q8_0
fallback was not downloaded.

### Load and memory

All configurations retained one 32768-token slot and loaded with the requested
target and draft layers offloaded to `Vulkan0`. No fit adjustment or
out-of-memory recovery occurred.

The following `amd-smi` samples were taken immediately after each measured
run. They are system-wide VRAM/GTT observations, including the desktop, rather
than per-process peak allocations.

| Configuration | Visible VRAM used | GTT used | Total observed |
| --- | ---: | ---: | ---: |
| Baseline | 3889 MiB | 19293 MiB | 23182 MiB |
| MTP, max 2 | 4009 MiB | 20905 MiB | 24914 MiB |
| MTP, max 3 | 3924 MiB | 21018 MiB | 24942 MiB |

### Performance

Each configuration ran the four-prompt set three times after one warmup.
Temperature was zero, seed was 42, and each response was capped at 64 tokens.
The 12 measured requests produced 744 target tokens per configuration.

| Configuration | Prompt tok/s | Generation tok/s | Median gen tok/s | Drafted | Accepted | Acceptance |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline | 9.82 | 3.86 | 3.82 | 0 | 0 | N/A |
| MTP, max 2 | 16.87 | 6.84 | 6.77 | 531 | 468 | 88.1% |
| MTP, max 3 | 16.53 | 7.15 | 7.37 | 660 | 510 | 77.3% |

Generation rates are aggregate target tokens divided by aggregate generation
time. Prompt rates are included for completeness but are affected by prefix
cache reuse. Compared with baseline, max 3 improved aggregate generation by
85.1 percent and median per-request generation by 93.2 percent.

### Functional checks

| Check | Result | Notes |
| --- | --- | --- |
| Text generation | Pass | Code, factual, JSON, and arithmetic prompts were coherent; the JSON response parsed successfully. |
| Vision | Pass | Correctly described five colored candies held in a hand. The first uncached image prompt took about 154 seconds to encode 4041 prompt tokens. |
| Structured tool call | Pass | Returned `get_weather` with valid arguments `{"city":"Singapore"}` and finish reason `tool_calls`. |
| Multi-turn context | Pass | Recalled the supplied project codename `Zephyr-19` exactly. |

## Known risks

- llama.cpp issue
  [#23577](https://github.com/ggml-org/llama.cpp/issues/23577) reports
  corrupted repeated output after very long Qwen 3.6 MTP sessions. A short
  smoke test cannot close this risk.
- MTP can introduce small deterministic-output differences through batched
  floating-point evaluation. Strict extraction workloads need their own
  regression suite.
- Results are specific to this quantization, Vulkan driver, power state, and
  single-stream configuration.

## Decision

The Q4_0 MTP sidecar is usable on this laptop and passes the experiment's
acceptance criteria. Use `--spec-draft-n-max 3` for this prompt mix: it was the
fastest aggregate and median configuration despite lower draft acceptance than
max 2. Max 2 remains a reasonable fallback for workloads whose acceptance
drops with the larger window.

Keep the Qwen configuration separate from the existing Gemma launcher for now.
The next integration step is a Qwen-specific launcher or explicit model
selection in a generalized launcher. Long-running use still needs monitoring
because the reported repeated-output issue was outside this short test's
scope.

Run the selected configuration from the repository root with:

```bash
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json \
./build-vulkan-amd/bin/llama-server \
  --model "$HOME/models/qwen3.6-27B/Qwen3.6-27B-Q4_K_M.gguf" \
  --mmproj "$HOME/models/qwen3.6-27B/mmproj-Qwen3.6-27B-Q8_0.gguf" \
  --device Vulkan0 \
  --gpu-layers 99 \
  --flash-attn auto \
  --fit off \
  --ctx-size 32768 \
  --parallel 1 \
  --jinja \
  --reasoning auto \
  --reasoning-preserve \
  --spec-type draft-mtp \
  --model-draft "$HOME/models/qwen3.6-27B/mtp-Qwen3.6-27B-Q4_0.gguf" \
  --device-draft Vulkan0 \
  --gpu-layers-draft 99 \
  --spec-draft-n-max 3 \
  --host 127.0.0.1 \
  --port 8094
```

## Next candidate: Qwen 3.6 35B-A3B

The other model considered for this experiment was
[`Qwen/Qwen3.6-35B-A3B`](https://huggingface.co/Qwen/Qwen3.6-35B-A3B).
It is a mixture-of-experts model with 35B total parameters but about 3B active
per token. It has 40 language-model layers and a hybrid layout combining
Gated DeltaNet, gated attention, and MoE blocks.

Expected behavior on this laptop:

- Baseline decode may be materially faster than dense 27B because each token
  activates far fewer parameters. The actual gain depends on Vulkan MoE
  kernels, expert routing overhead, and shared-memory bandwidth.
- The complete expert weights must still remain mapped. A Q4 model is expected
  to use more memory than the 19.1 GB dense target, leaving less of the roughly
  32 GB shared graphics memory for context, compute buffers, and the vision
  projector.
- MTP may provide a smaller relative gain than it did for dense 27B because
  normal MoE token generation is already cheaper. The draft overhead can
  become the bottleneck even when acceptance is high.
- The official
  [`ggml-org/Qwen3.6-35B-A3B-MTP-GGUF`](https://huggingface.co/ggml-org/Qwen3.6-35B-A3B-MTP-GGUF)
  instructions recommend testing draft windows of two and three tokens.

Do not assume that high acceptance guarantees a speedup. llama.cpp issue
[#23011](https://github.com/ggml-org/llama.cpp/issues/23011) reported a severe
MTP slowdown under Metal memory pressure, and issue
[#23230](https://github.com/ggml-org/llama.cpp/issues/23230) reported smaller
post-cleanup regressions including Vulkan results. These reports are not
measurements of this AMD laptop, but they make baseline, max-2, and max-3 runs
mandatory. Use [the local evaluation protocol](local-evals.md) for that test.
