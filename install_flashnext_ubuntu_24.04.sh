#!/usr/bin/env bash
set -euxo pipefail

# ============================================================
# FLASHNEXT INSTALL SCRIPT
# Ubuntu 24.04 + 2x NVIDIA CMP 170HX
# Based on README of:
#   https://github.com/tuxblanko-sudo/qwen38-flash-next-2x-cmp170hx
# ============================================================

export DEBIAN_FRONTEND=noninteractive
export FLASHNEXT_ROOT="${FLASHNEXT_ROOT:-/opt/flashnext}"
export FLASHNEXT_REPO="https://github.com/tuxblanko-sudo/qwen38-flash-next-2x-cmp170hx.git"
export VLLM_BACKPORT_REPO="https://github.com/wtdcode/vllm-backport.git"
export VLLM_BACKPORT_REF="3142ded1671b9565503975ee946d7e19fe50ea95"
export CMPUNLOCKER_REPO="https://github.com/amoghmunikote/cmpunlocker.git"
export CMPUNLOCKER_TAG="v0.5"

if [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
Usage:
  ./install_flashnext_ubuntu_24.04.sh
  ./install_flashnext_ubuntu_24.04.sh --resume

This script performs the base setup for the Qwen3.8-Flash-Next + CMP170HX setup.
It stops before reboot so the NVIDIA driver and cmpunlocker can be applied.
After reboot, run with --resume.
EOF
  exit 0
fi

# ---- Step 1: base system packages ----
if [ "${1:-}" != "--resume" ]; then
  echo "=== 1) System setup ==="
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    ca-certificates curl git wget build-essential \
    pkg-config cmake ninja-build unzip jq \
    python3 python3-venv python3-pip python3-dev \
    linux-headers-$(uname -r) dkms

  echo "=== 2) Create work dirs ==="
  sudo mkdir -p "$FLASHNEXT_ROOT"
  sudo chown -R "$USER:$USER" "$FLASHNEXT_ROOT"

  echo "=== 3) Clone project repo ==="
  if [ ! -d "/opt/qwen38-flash-next-2x-cmp170hx" ]; then
    git clone "$FLASHNEXT_REPO" /opt/qwen38-flash-next-2x-cmp170hx
  fi
  cp /opt/qwen38-flash-next-2x-cmp170hx/scripts/checkpoint-source.json "$FLASHNEXT_ROOT/checkpoint-source.json"

  echo "=== 4) Install NVIDIA open driver + cmpunlocker ==="
  echo "NOTE:"
  echo "  This repo expects a working open/unsigned NVIDIA stack."
  echo "  README mentions nvidia-open 610.43.02 + cmpunlocker v0.5+"
  echo "  This step MUST be done on the actual target machine."
  echo ""
  echo "  The commands below install the repo and then stop before reboot."
  echo "  After a reboot, run:"
  echo "    ./install_flashnext_ubuntu_24.04.sh --resume"

  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg
  echo "deb [signed-by=/usr/share/keyrings/nvidia-cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /" | \
    sudo tee /etc/apt/sources.list.d/nvidia-cuda.list

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends nvidia-driver-570 || \
    sudo apt-get install -y --no-install-recommends nvidia-driver-550 || true

  if [ ! -d "/tmp/cmpunlocker" ]; then
    git clone --branch "$CMPUNLOCKER_TAG" --depth 1 "$CMPUNLOCKER_REPO" /tmp/cmpunlocker
  fi

  cd /tmp/cmpunlocker
  sudo ./install.sh --profile=8gb --no-iommu
  sudo systemctl disable cmpunlocker-passthrough.service || true

  echo "================================================================"
  echo " Reboot required to apply the driver and unlocker settings."
  echo " After reboot, continue with:"
  echo "   ./install_flashnext_ubuntu_24.04.sh --resume"
  echo "================================================================"
  exit 0
fi

# ---- Step 2: clone vLLM backport and build environment ----
# This is the step after successful reboot and driver install.
echo "=== 5) Clone vLLM backport and checkout exact commit ==="
if [ ! -d "$FLASHNEXT_ROOT/vllm-backport" ]; then
  git clone "$VLLM_BACKPORT_REPO" "$FLASHNEXT_ROOT/vllm-backport"
fi

cd "$FLASHNEXT_ROOT/vllm-backport"
git fetch --all --tags
git checkout "$VLLM_BACKPORT_REF"

# README: apply the repo patch
if [ -f /opt/qwen38-flash-next-2x-cmp170hx/patches/vllm-backport-3142ded1.patch ]; then
  git apply /opt/qwen38-flash-next-2x-cmp170hx/patches/vllm-backport-3142ded1.patch
fi

# Create venv and install build dependencies
python3.12 -m venv "$FLASHNEXT_ROOT/vllm-backport/.venv"
source "$FLASHNEXT_ROOT/vllm-backport/.venv/bin/activate"
python -m pip install --upgrade pip setuptools wheel
python -m pip install --upgrade "numpy<2" "cmake>=3.26" ninja packaging requests

if [ -f requirements/build.txt ]; then
  python -m pip install -r requirements/build.txt
fi
if [ -f requirements/cuda.txt ]; then
  python -m pip install -r requirements/cuda.txt
fi
if [ -f requirements/common.txt ]; then
  python -m pip install -r requirements/common.txt
fi

python -m pip install -e .

# install repo plugins
python -m pip install \
  -e /opt/qwen38-flash-next-2x-cmp170hx/plugins/tinybeast-ple-int4 \
  -e /opt/qwen38-flash-next-2x-cmp170hx/plugins/tinybeast-ple-ssd

# prepare conversion model
cd /opt/qwen38-flash-next-2x-cmp170hx
FLASHNEXT_ROOT="$FLASHNEXT_ROOT" python3 scripts/prepare_checkpoint.py

# copy serve.sh to root
cp /opt/qwen38-flash-next-2x-cmp170hx/serve/serve.sh "$FLASHNEXT_ROOT/serve.sh"
chmod +x "$FLASHNEXT_ROOT/serve.sh"

cat <<EOF

Setup complete up to model preparation.
Next step:
  bash "$FLASHNEXT_ROOT/serve.sh"

This runs vLLM on 127.0.0.1:18084 with model name:
  tinybeast-flashnext-uncensored
EOF
