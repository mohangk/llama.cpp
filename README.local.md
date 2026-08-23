# Local llama.cpp operating notes

This is the operating manual for the personal fork. It separates shared server and repository policy from machine-specific build and performance notes.

## Machine profiles

| Profile | Hardware | Preferred backend | Status | Documentation |
| --- | --- | --- | --- | --- |
| `minipc-nvidia` | Intel Core Ultra 9 185H, NVIDIA RTX 3090, 93 GiB RAM | CUDA | Validated | [Mini PC NVIDIA profile](doc-local/machines/minipc-nvidia.md) |
| `amd-ryzen` | AMD Ryzen AI 7 PRO 350, Radeon 860M, 58 GiB RAM | Vulkan RADV | Validated | [AMD Ryzen laptop profile](doc-local/machines/amd-ryzen.md) |
| Mac | Not inspected in this workflow | Deferred | Inspect on the Mac before choosing flags | Not created |

Do not copy performance conclusions between profiles. Compiler, driver, memory, power, and thermal differences can be larger than small build-option gains.

## Quick start

### NVIDIA mini PC

Build the production CUDA baseline:

```bash
./local-scripts/minipc-nvidia-build.sh baseline
```

Run a smoke benchmark with a readable absolute model path:

```bash
LLAMA_MODEL=/path/to/model.gguf \
  ./local-scripts/minipc-nvidia-bench.sh baseline smoke
```

Start the model-neutral server launcher:

```bash
LLAMA_MODEL=/path/to/model.gguf \
  ./local-scripts/minipc-nvidia-run.sh
```

The available Qwen 3.6 27B benchmark artifact and its checksum are recorded in the [mini PC profile](doc-local/machines/minipc-nvidia.md#benchmark-artifact).

### AMD Ryzen laptop

Build the validated Vulkan profile:

```bash
./local-scripts/amd-ryzen-build.sh
```

The preserved Gemma 4 launcher is:

```bash
./local-scripts/amd-ryzen-run.sh
```

Its model defaults, Vulkan environment, and MTP behavior are documented in the [Gemma 4 setup](doc-local/gemma4.md) and the [AMD machine profile](doc-local/machines/amd-ryzen.md).

## Local scripts

| Script | Purpose |
| --- | --- |
| `local-scripts/minipc-nvidia-build.sh` | Build the selected CUDA baseline for the RTX 3090. Comparison arguments remain available for future retesting. |
| `local-scripts/minipc-nvidia-run.sh` | Run a model supplied through `LLAMA_MODEL` on the selected baseline and `CUDA0`. |
| `local-scripts/minipc-nvidia-bench.sh` | Run smoke, core, or tuning benchmarks and retain JSON, telemetry, metadata, and a Markdown summary. |
| `local-scripts/amd-ryzen-build.sh` | Build the validated Vulkan profile for the Radeon 860M laptop. |
| `local-scripts/amd-ryzen-run.sh` | Run the validated AMD Vulkan Gemma 4 configuration. |

Build directories and raw benchmark results are not tracked. Mini PC benchmark results default to `${XDG_STATE_HOME:-$HOME/.local/state}/llama.cpp/benchmarks/minipc-nvidia/`.

## Evaluation documents

- [Local evaluation protocol](doc-local/local-evals.md)
- [Gemma 4 setup and AMD results](doc-local/gemma4.md)
- [Qwen 3.6 27B AMD MTP experiment](doc-local/qwen36-mtp-plan.md)

Add results to a machine profile or model result document only after recording the exact machine, llama.cpp revision, backend, build options, driver, model hash, and runtime settings.

## Server tools

The local server launchers enable these experimental built-in tools explicitly:

- `read_file`: read a file or selected line range
- `file_glob_search`: find files with a glob pattern
- `grep_search`: search file contents
- `exec_shell_command`: execute a command through `sh -c`
- `write_file`: create or overwrite a file
- `edit_file`: replace text in a file
- `get_info`: return the server OS and working directory

The explicit list prevents new llama.cpp tools from becoming available without review. The launchers do not use `--agent` because it also enables the MCP CORS proxy and implicitly enables every built-in tool.

### Using tools in the Web UI

1. Start the machine-specific run script and open `http://127.0.0.1:8080`.
2. Ask the model to perform a concrete action, such as reporting the current time or reading a known file.
3. Inspect the proposed tool and its arguments.
4. Select `Allow once` only when the call is expected.
5. Deny unexpected calls, especially commands or writes suggested by content the model just read.

Do not use persistent approval for this configuration. If it is selected accidentally, revoke it in the Chat Tools settings. Permissions are stored in browser local storage and are not enforced by the server.

### Tool implementation limits

- `read_file` returns at most 16 KiB unless a line range narrows the request.
- Shell output is limited to 16 KiB.
- Shell timeout is capped at 60 seconds.
- File searches are bounded to 100 results.
- Paths are passed to the host filesystem without a configured allowed root.

`GET /tools` lists enabled built-ins and `POST /tools` invokes one. These endpoints are internal to llama-server and can change. External applications should use the OpenAI-compatible chat API and implement their own tool loop.

Relevant upstream material:

- [Server usage and built-in tools](tools/server/README.md)
- [Server development and endpoint scope](tools/server/README-dev.md)
- [Initial built-in tool implementation](https://github.com/ggml-org/llama.cpp/pull/20898)
- [Web UI agent loop and approvals](https://github.com/ggml-org/llama.cpp/pull/21237)

## Security model

This is a high-trust local configuration. Enabled tools run with the permissions of the user who starts llama-server.

- File reads, writes, and edits are not confined to this repository.
- Shell commands inherit the server environment, current user, `PATH`, network access, and filesystem access.
- Launchers change to the repository root, so relative shell paths start here. This is not a sandbox.
- A model can propose harmful calls because of a prompt, hallucination, or prompt injection.
- CORS restrictions do not provide authentication.

The server binds only to `127.0.0.1` and has no API key. Another local process can call the API directly, and a direct `POST /tools` request does not display a Web UI approval prompt. Do not expose port 8080 through a LAN binding, reverse proxy, tunnel, container port publication, or firewall rule.

Use a separate Unix account, container, or virtual machine before opening untrusted projects. The local launchers do not claim to provide a filesystem or command sandbox.

## Shared verification checklist

After changing a launcher, model, build, or llama.cpp revision:

```bash
bash -n local-scripts/*.sh
git diff --check
```

Verify the selected binary and device:

```bash
./build-minipc-nvidia/bin/llama-cli --version
./build-minipc-nvidia/bin/llama-cli --list-devices
```

With a server running:

```bash
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/v1/models
curl --fail http://127.0.0.1:8080/tools
curl --fail --compressed --output /dev/null http://127.0.0.1:8080/
```

Use `ss -ltnp` to confirm that the process listens only on `127.0.0.1:8080`. Test a known file read and `pwd` through the Web UI with `Allow once`, then stop the server and confirm the port is closed.

## Personal fork workflow

The local documentation and scripts belong only to the personal fork. No upstream pull request is planned.

The intended topology is:

- Remote `upstream`: `git@github.com:ggml-org/llama.cpp.git`
- Remote `origin`: `git@github.com:mohangk/llama.cpp.git`
- Branch `master`: personal changes rebased on `upstream/master`

All GitHub forks of a public repository are public. Do not add API keys, credentials, private host details, model files, generated output, or raw benchmark artifacts to these commits.

Review and commit only intended local files:

```bash
git status --short
git add README.local.md local-scripts doc-local
git diff --cached
git commit
```

If an AI assistant is explicitly authorized to commit, disclose its assistance with an `Assisted-by:` trailer. An agent may push to `origin` only with explicit user approval and must never create a pull request.

### Synchronize with upstream

Keep personal-fork commits on top of the latest `upstream/master` history:

```bash
git status --short
git fetch upstream --prune
git rebase upstream/master
```

Do not merge `upstream/master` into the personal branch. Resolve conflicts and run checks appropriate to affected files. After explicit user approval, update the fork with:

```bash
git push --force-with-lease origin master
```

Never force-push to `upstream`.
