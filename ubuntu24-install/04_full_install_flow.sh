#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================
# 04_full_install_flow.sh
# Full orchestration for Ubuntu 24.04 + 2x CMP 170HX
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

info()  { printf '\n[INFO] %s\n' "$*"; }
warn()  { printf '\n[WARN] %s\n' "$*"; }
error() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

check_root() {
  [ "$(id -u)" -eq 0 ] || error "Run as root: sudo bash $0"
}

check_ubuntu_24() {
  if [ ! -f /etc/os-release ]; then
    error "/etc/os-release not found"
  fi
  . /etc/os-release
  if [ "$VERSION_ID" != "24.04" ]; then
    warn "Detected Ubuntu $VERSION_ID ($NAME)"
    warn "This flow is designed for Ubuntu 24.04. Continue only if you know what you are doing."
  fi
}

stage_driver_and_unlocker() {
  info "Stage 1: install NVIDIA driver and cmpunlocker"
  bash "$SCRIPT_DIR/01_install_nvidia_and_cmpunlocker.sh"
  info "Driver + unlocker installation finished. A reboot is required."
  info "Reboot now and then rerun this script."
  exit 0
}

stage_build_and_model() {
  info "Stage 2: build vLLM backport + install plugins + prepare model"
  bash "$SCRIPT_DIR/02_build_vllm_and_prepare_model.sh"
}

stage_start() {
  info "Stage 3: start API server and run smoke test"
  bash "$SCRIPT_DIR/03_start_flashnext_api.sh"
}

main() {
  check_root
  check_ubuntu_24

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    stage_driver_and_unlocker
  fi

  if ! nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi still not available after driver installation."
    warn "Reboot first and rerun the script."
    exit 1
  fi

  if [ ! -d "$FLASHNEXT_ROOT/model-awq-int4ple" ] 2>/dev/null || [ ! -d "$FLASHNEXT_ROOT/vllm-backport/.venv" ] 2>/dev/null; then
    stage_build_and_model
  else
    info "Build and model directories already exist; skipping stage 2."
  fi

  stage_start
  info "Done. FlashNext API is available on http://127.0.0.1:18084"
}

main "$@"
