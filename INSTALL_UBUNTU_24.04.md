# Ubuntu 24.04 install guide for Qwen3.8-Flash-Next on 2x CMP 170HX

This repository contains the project-specific setup scripts for an Ubuntu 24.04 installation of the Qwen3.8-Flash-Next stack using two NVIDIA CMP 170HX mining cards.

Important note about CUDA

- You do not need a full system-wide CUDA Toolkit apt install for this setup.
- The project expects the NVIDIA driver and open kernel modules, then the CUDA runtime used by the vLLM build is installed inside the Python virtual environment created in the project.
- The repository itself sets:
  - `CUDA_HOME="$FLASHNEXT_ROOT/vllm-backport/.venv/lib/python3.12/site-packages/nvidia/cu13"`
  - `NVCC_CCBIN=/usr/bin/g++-13`
- This means the stack relies on the CUDA packages bundled in the vLLM environment, not on a separate `/usr/local/cuda` toolchain.
- In practice, install the NVIDIA driver and use the vLLM Python environment; do not assume you must install `cuda-toolkit` with `apt`.

Hardware and OS assumptions

- Ubuntu 24.04
- 2x NVIDIA CMP 170HX (unlocked to 64 GiB each)
- NVIDIA open driver stack via `nvidia-open` / compatible package
- cmpunlocker v0.5+
- vLLM backport fork from `wtdcode/vllm-backport`
- project patch from this repo

Repository scripts

The repo includes the following automation:

- `scripts/install_cmp_unlocker_ubuntu_24.04.sh`
  Installs NVIDIA driver packages and cmpunlocker, with checks.

- `scripts/setup_vllm_and_model_ubuntu_24.04.sh`
  Clones the vLLM backport, applies the patch, creates the Python venv, installs the vLLM fork, installs the tinybeast plugins, and prepares the model checkpoint.

- `scripts/start_flashnext_api_ubuntu_24.04.sh`
  Starts the API and performs a smoke test against the OpenAI-compatible endpoint.

- `scripts/install_flashnext_full_ubuntu_24.04.sh`
  Orchestrates the full sequence end-to-end.

Recommended order

1. Install the NVIDIA driver and cmpunlocker
2. Reboot the machine
3. Build vLLM + install plugins + prepare model
4. Start the server
5. Verify the health endpoint and a chat-completion request

Commands

Install driver and unlocker:

```bash
sudo bash scripts/install_cmp_unlocker_ubuntu_24.04.sh
```

Reboot the machine after the script finishes.

Then build the project stack:

```bash
sudo bash scripts/setup_vllm_and_model_ubuntu_24.04.sh
```

Then start the API:

```bash
bash scripts/start_flashnext_api_ubuntu_24.04.sh
```

Or run the full sequence in one go:

```bash
sudo bash scripts/install_flashnext_full_ubuntu_24.04.sh
```

This script will stop after the driver install and tell you to reboot. After reboot, run it again and it continues automatically.

What to expect on the machine

- `nvidia-smi` should show each CMP 170HX near 65536 MiB and ECC enabled after unlock
- the model is loaded from `$FLASHNEXT_ROOT/model-awq-int4ple`
- the API listens on `127.0.0.1:18084`
- model name: `tinybeast-flashnext-uncensored`

Validation checks

After install, verify:

```bash
nvidia-smi
nvidia-smi --query-gpu=memory.total --format=csv,noheader
```

You should see roughly 65536 MiB on each card after unlock.

Then verify the server:

```bash
curl http://127.0.0.1:18084/health
```

And a smoke test:

```bash
curl -X POST http://127.0.0.1:18084/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"tinybeast-flashnext-uncensored","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":32,"temperature":0.0}'
```

Troubleshooting

- If `nvidia-smi` does not see the cards: check PCIe visibility, BIOS settings, and whether the driver is loaded.
- If `cmpunlocker` fails: make sure you are using the correct profile and the cards are visible before running the script.
- If the model build fails: verify Python 3.12 and the vLLM fork commit in the script.
- If the API fails to start: inspect `$FLASHNEXT_ROOT/flashnext.log`.

Additional note

This project uses a patched vLLM fork and custom plugins. It is not a standard upstream `vllm` install. The environment must be built from source and the project patch must be applied.
