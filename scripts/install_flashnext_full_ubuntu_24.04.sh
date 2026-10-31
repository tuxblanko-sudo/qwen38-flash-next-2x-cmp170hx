#!/usr/bin/env bash
set -Eeuo pipefail

# Full installation flow for Ubuntu 24.04 + 2x CMP 170HX
# Runs the project scripts in the intended order.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
  bash "$REPO_ROOT/scripts/install_cmp_unlocker_ubuntu_24.04.sh"
  info "Driver + unlocker installation finished. A reboot is required."
  info "Reboot now and then rerun this script."
  exit 0
}

stage_build_and_model() {
  info "Stage 2: build vLLM backport + install plugins + prepare model"
  bash "$REPO_ROOT/scripts/setup_vllm_and_model_ubuntu_24.04.sh"
}

stage_start() {
  info "Stage 3: start API server and run smoke test"
  bash "$REPO_ROOT/scripts/start_flashnext_api_ubuntu_24.04.sh"
}

main() {
  check_root
  check_ubuntu_24

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    stage_driver_and_unlocker
  fi

  # If NVIDIA is present, proceed to build and model prep.
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
