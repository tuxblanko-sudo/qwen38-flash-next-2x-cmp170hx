#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================
# Part 3/4: build vLLM backport, install plugins, prepare model
# Ubuntu 24.04 + 2x NVIDIA CMP 170HX
# =============================================================

export DEBIAN_FRONTEND=noninteractive
export FLASHNEXT_ROOT="${FLASHNEXT_ROOT:-/opt/flashnext}"
export VLLM_BACKPORT_REPO="https://github.com/wtdcode/vllm-backport.git"
export VLLM_BACKPORT_REF="3142ded1671b9565503975ee946d7e19fe50ea95"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

info()  { printf '\n[INFO] %s\n' "$*"; }
warn()  { printf '\n[WARN] %s\n' "$*"; }
error() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || error "Run as root: sudo bash $0"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

check_python312() {
  if ! command -v python3.12 >/dev/null 2>&1; then
    info "Installing python3.12"
    apt-get update
    apt-get install -y --no-install-recommends python3.12 python3.12-venv python3.12-dev || \
      error "python3.12 is required by the vLLM backport fork"
  fi
}

check_nvidia() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    error "nvidia-smi not found. Install the NVIDIA driver and unlocker first."
  fi

  info "Current GPU state:"
  nvidia-smi || true
}

prepare_dirs() {
  mkdir -p "$FLASHNEXT_ROOT"
  chown -R "$USER:$USER" "$FLASHNEXT_ROOT" || true

  # README expects checkpoint-source.json in FLASHNEXT_ROOT root
  if [ -f "$PROJECT_ROOT/scripts/checkpoint-source.json" ]; then
    cp "$PROJECT_ROOT/scripts/checkpoint-source.json" "$FLASHNEXT_ROOT/checkpoint-source.json"
  fi
}

clone_vllm() {
  if [ ! -d "$FLASHNEXT_ROOT/vllm-backport" ]; then
    info "Cloning vllm-backport"
    git clone "$VLLM_BACKPORT_REPO" "$FLASHNEXT_ROOT/vllm-backport"
  else
    info "vllm-backport already exists"
  fi

  cd "$FLASHNEXT_ROOT/vllm-backport"
  git fetch --all --tags || true
  git checkout "$VLLM_BACKPORT_REF" || error "Failed to checkout $VLLM_BACKPORT_REF"

  if [ -f "$PROJECT_ROOT/patches/vllm-backport-3142ded1.patch" ]; then
    info "Applying repo patch"
    git apply "$PROJECT_ROOT/patches/vllm-backport-3142ded1.patch" || \
      warn "Patch may already be applied; continuing"
  else
    warn "Patch file not found: $PROJECT_ROOT/patches/vllm-backport-3142ded1.patch"
  fi
}

setup_python_env() {
  info "Creating venv in $FLASHNEXT_ROOT/vllm-backport/.venv"
  python3.12 -m venv "$FLASHNEXT_ROOT/vllm-backport/.venv"
  # shellcheck disable=SC1091
  source "$FLASHNEXT_ROOT/vllm-backport/.venv/bin/activate"

  python -m pip install --upgrade pip setuptools wheel
  python -m pip install --upgrade "numpy<2" "cmake>=3.26" ninja packaging requests

  if [ -f "$FLASHNEXT_ROOT/vllm-backport/requirements/build.txt" ]; then
    python -m pip install -r "$FLASHNEXT_ROOT/vllm-backport/requirements/build.txt"
  fi
  if [ -f "$FLASHNEXT_ROOT/vllm-backport/requirements/cuda.txt" ]; then
    python -m pip install -r "$FLASHNEXT_ROOT/vllm-backport/requirements/cuda.txt"
  fi
  if [ -f "$FLASHNEXT_ROOT/vllm-backport/requirements/common.txt" ]; then
    python -m pip install -r "$FLASHNEXT_ROOT/vllm-backport/requirements/common.txt"
  fi

  info "Installing vLLM from source"
  cd "$FLASHNEXT_ROOT/vllm-backport"
  python -m pip install -e .
}

install_plugins() {
  info "Installing TinyBeast plugins"
  python -m pip install \
    -e "$PROJECT_ROOT/plugins/tinybeast-ple-int4" \
    -e "$PROJECT_ROOT/plugins/tinybeast-ple-ssd"
}

prepare_model() {
  info "Preparing model and conversion to int4 PLE format"
  cd "$PROJECT_ROOT"
  FLASHNEXT_ROOT="$FLASHNEXT_ROOT" python3 scripts/prepare_checkpoint.py
}

copy_launcher() {
  mkdir -p "$FLASHNEXT_ROOT"
  cp "$PROJECT_ROOT/serve/serve.sh" "$FLASHNEXT_ROOT/serve.sh"
  chmod +x "$FLASHNEXT_ROOT/serve.sh"
}

final_checks() {
  info "Final structure check"
  [ -d "$FLASHNEXT_ROOT/vllm-backport/.venv" ] || error "venv missing"
  [ -d "$FLASHNEXT_ROOT/model-awq-int4ple" ] || error "Converted model directory missing"
  [ -f "$FLASHNEXT_ROOT/checkpoint-source.json" ] || error "checkpoint-source.json missing"
  [ -f "$FLASHNEXT_ROOT/serve.sh" ] || error "serve.sh missing"

  info "Everything is ready. To start the server, run:"
  info "  bash $FLASHNEXT_ROOT/serve.sh"
  info "or"
  info "  source $FLASHNEXT_ROOT/vllm-backport/.venv/bin/activate && export FLASHNEXT_ROOT=$FLASHNEXT_ROOT && bash $FLASHNEXT_ROOT/serve.sh"
}

main() {
  require_root
  require_command git
  require_command curl
  require_command wget

  check_python312
  check_nvidia
  prepare_dirs
  clone_vllm
  setup_python_env
  install_plugins
  prepare_model
  copy_launcher
  final_checks
}

main "$@"
