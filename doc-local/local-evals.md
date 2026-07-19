# Local model evaluation protocol

This document defines the repeatable local evaluation used to compare models,
quantizations, inference backends, and speculative decoding configurations on
this laptop. It separates a small deterministic performance test from
capability checks so results remain comparable without treating token speed as
the only useful outcome.

## Evaluation registry

| Date | Model | Backend | Result |
| --- | --- | --- | --- |
| 2026-07-19 | Gemma 4 12B QAT Q4 | Vulkan, AMD Radeon 860M | [Baseline and MTP evaluation](gemma4.md#controlled-local-evaluation) |
| 2026-07-19 | Qwen 3.6 27B Q4_K_M | Vulkan, AMD Radeon 860M | [Baseline and MTP evaluation](qwen36-mtp-plan.md) |

Add one result document per materially different model or setup. Do not
overwrite an older result after changing the llama.cpp revision, backend,
driver, quantization, context size, or speculative decoder.

## Run identity

Record these fields before testing:

- Date and local time.
- llama.cpp version and Git commit.
- Build directory and relevant CMake options.
- Backend, device name, driver, and Vulkan ICD.
- Laptop power source and power profile.
- Target, projector, and drafter paths.
- File sizes, SHA-256 hashes, repository, and pinned repository revision.
- GGUF architecture, quantization, native context, embedding width, tokenizer
  IDs, chat-template presence, and MTP metadata.
- Server context, parallel slots, batch settings, KV types, flash attention,
  fit behavior, and layer offload settings.

Keep the machine otherwise idle. Record temperature before the first run and
after every configuration. Thermal or background-load changes can be larger
than small differences between configurations.

## Configuration matrix

At minimum, compare:

1. Target model without speculative decoding.
2. The same target with the intended drafter and a two-token maximum window.
3. The same target and drafter with a three-token maximum window.

Change only speculative-decoding options between these runs. Keep the target,
projector, context, sampling, prompt order, and offload settings identical.
Start a fresh server process for each configuration.

For target-specific MTP, use:

```text
--spec-type draft-mtp
--spec-draft-n-max 2 or 3
```

Add `--model-draft`, `--device-draft`, and `--gpu-layers-draft` when the MTP
head is stored in a separate GGUF. Some self-MTP models embed the required head
in the target and do not need a separate draft path.

## Preflight checks

1. Verify every artifact against its expected byte size and SHA-256 hash.
2. Inspect GGUF metadata for target-drafter compatibility.
3. Confirm the server binary exposes every option used by the test.
4. Confirm enough shared GPU memory and disk space are available.
5. Confirm the test port is unused.
6. Start the server and retain its load and timing logs.
7. Check `GET /health` and `GET /v1/models`.
8. Confirm the requested context, parallel slots, projector, target layers,
   and draft layers loaded without automatic fit changes or OOM recovery.

## Deterministic text benchmark

Use the OpenAI-compatible `POST /v1/chat/completions` endpoint. The fixed
request settings are:

```text
temperature: 0
seed: 42
max_tokens: 64
enable_thinking: false, when supported by the template
stream: false
```

Temperature zero is intentional for this regression suite. If normal usage
samples at a nonzero temperature, add a separate representative-workload run
instead of changing this deterministic result.

Warm up once with:

```text
Reply with exactly: ready
```

Then run these four prompts in order, three times each:

1. Code:

   ```text
   Write a Python function that merges two sorted integer lists. Return code only.
   ```

2. Factual explanation:

   ```text
   Explain Rayleigh scattering in three concise sentences.
   ```

3. Structured JSON:

   ```text
   Return JSON only with keys name, version, and features, describing the Python language. The features value must be an array of three strings.
   ```

4. Arithmetic reasoning:

   ```text
   A box has 12 red, 8 blue, and 5 green balls. If 7 red and 3 blue balls are removed, how many balls remain? Give the calculation and answer.
   ```

This produces 12 measured requests per configuration. The 64-token cap keeps
the throughput test short and comparable, but it can truncate longer answers.
Use the functional checks below for correctness rather than treating truncated
benchmark answers as failures.

## Performance metrics

Store the complete JSON response for every request. Record:

- Request count and total predicted target tokens.
- Aggregate generation rate:
  `sum(predicted_n) / (sum(predicted_ms) / 1000)`.
- Median per-request generation rate. For an even request count, average the
  two middle sorted `predicted_per_second` values.
- Aggregate prompt rate:
  `sum(prompt_n) / (sum(prompt_ms) / 1000)`.
- Draft tokens, accepted draft tokens, and aggregate acceptance rate.
- Finish reasons, HTTP errors, server warnings, and crashes.
- Visible VRAM, GTT, temperature, and load time.

Prompt caching affects repeated prompt rates, so generation speed is the
primary comparison. System-wide `amd-smi` readings include the desktop and are
not exact per-process peak allocations; label them accordingly.

Use this performance table in each result document:

| Configuration | Prompt tok/s | Generation tok/s | Median gen tok/s | Drafted | Accepted | Acceptance |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline | | | | 0 | 0 | N/A |
| Draft, max 2 | | | | | | |
| Draft, max 3 | | | | | | |

## Functional checks

Run these against the fastest configuration that meets the speculative
acceptance threshold. Run applicable checks against baseline too if a failure
could be caused by the drafter.

### Text and structure

- Confirm the four benchmark outputs are coherent despite any token-limit
  truncation.
- Parse the JSON prompt response with a real JSON parser.
- Confirm it contains `name`, `version`, and a three-string `features` array.
- Run a longer uncapped or 128-token code request if code completeness matters.
- Confirm the arithmetic answer is 15.

### Vision

Send typed `text` and `image_url` content using:

```text
https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/p-blog/candy.JPG
```

Prompt:

```text
Describe the main objects in this image in one concise sentence.
```

Confirm the response identifies a hand holding five colored candies. Record
cold image-download and image-encoding time separately from a repeated request
that can reuse the prompt cache. Recheck server health after vision processing.

### Structured tool call

Provide one OpenAI-compatible function named `get_weather` with a required
string argument named `city`. Prompt:

```text
What is the current weather in Singapore? Use the available tool.
```

Confirm:

- Finish reason is `tool_calls`.
- Function name is `get_weather`.
- Arguments parse as JSON.
- The `city` value is `Singapore`.

The test checks model output structure only. Do not execute the tool.

### Multi-turn context

Send this message history in one chat-completion request:

```text
user: My project codename is Zephyr-19. Acknowledge with one word.
assistant: Acknowledged.
user: What is my project codename? Reply with only the codename.
```

Confirm the response is exactly `Zephyr-19` and the server remains healthy.

## Acceptance criteria

A configuration passes when:

- Artifacts and metadata match the intended target, projector, and drafter.
- The requested 32768-token context and one parallel slot load without OOM or
  an unrequested fit reduction.
- Text output is coherent and structured JSON parses correctly.
- Supported vision, tool-call, and multi-turn checks pass.
- Aggregate draft acceptance is at least 50 percent.
- At least one speculative configuration improves median generation speed by
  at least 15 percent over baseline.
- No request crashes the server or leaves it unhealthy.

A model can still be useful when speculative decoding fails these thresholds.
In that case, select baseline and record the drafter as a regression rather
than rejecting the target model.

## Extended checks

The short suite does not cover long-context quality, extended multi-turn slot
reuse, concurrent requests, prompt-cache invalidation, sustained thermals, or
hours-long MTP stability. Add those tests when they match the intended use.
Keep their results separate from the fixed 12-request benchmark.

## Cleanup

After every configuration:

1. Capture final logs and resource observations.
2. Stop the server cleanly.
3. Confirm the test port is no longer listening.
4. Retain raw response JSON outside the repository or summarize it in the
   model-specific result document.
5. Run documentation whitespace and ASCII checks before committing local
   result updates.
