#!/usr/bin/env bash
set -Eeuo pipefail

# ================================================
# Part 2: install NVIDIA open driver + cmpunlocker
# Ubuntu 24.04, for 2x NVIDIA CMP 170HX
# ================================================

export DEBIAN_FRONTEND=noninteractive

REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/"
KEYRING="/usr/share/keyrings/nvidia-cuda.gpg"
NVIDIA_REPO_FILE="/etc/apt/sources.list.d/nvidia-cuda.list"
CMPUNLOCKER_REPO="https://github.com/amoghmunikote/cmpunlocker.git"
CMPUNLOCKER_TAG="v0.5"

info()  { printf '\n[INFO] %s\n' "$*"; }
warn()  { printf '\n[WARN] %s\n' "$*"; }
error() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || error "Run as root: sudo bash $0"
}

check_os() {
  if [ ! -f /etc/os-release ]; then
    error "Cannot detect OS: /etc/os-release is missing"
  fi
  . /etc/os-release
  if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    warn "Detected Ubuntu $VERSION_ID ($NAME) — this script is designed for Ubuntu 24.04."
    warn "Proceed only if you know what you are doing."
  fi
}

check_kernel_headers() {
  if ! dpkg -s linux-headers-$(uname -r) >/dev/null 2>&1; then
    info "Installing linux-headers for current kernel"
    apt-get install -y --no-install-recommends linux-headers-$(uname -r) dkms
  fi
}

check_nvidia_card() {
  if ! command -v lspci >/dev/null 2>&1; then
    apt-get install -y pciutils
  fi

  if ! lspci | grep -qi "10de:20c2\|NVIDIA.*CMP\|CMP 170HX"; then
    warn "No CMP 170HX device found in lspci output."
    warn "This may be a different GPU or the cards are not visible yet."
    warn "Continue only if these cards are really installed and expected."
  fi
}

install_nvidia_repo() {
  info "Adding NVIDIA CUDA repository"
  curl -fsSL "${REPO_URL}3bf863cc.pub" | gpg --dearmor -o "$KEYRING" 2>/dev/null || \
    curl -fsSL "${REPO_URL}/3bf863cc.pub" | gpg --dearmor -o "$KEYRING" 2>/dev/null || \
    error "Failed to fetch NVIDIA signing key"

  printf '%s\n' "deb [signed-by=${KEYRING}] ${REPO_URL} /" > "$NVIDIA_REPO_FILE"
  apt-get update
}

install_open_driver() {
  info "Installing NVIDIA driver package (open kernel module)"

  # Prefer current open-driver package first, then fall back to a common alternative.
  if ! apt-get install -y --no-install-recommends nvidia-driver-570-open; then
    if ! apt-get install -y --no-install-recommends nvidia-driver-550-open; then
      apt-get install -y --no-install-recommends nvidia-driver-570 || \
        apt-get install -y --no-install-recommends nvidia-driver-550 || \
        error "Failed to install NVIDIA driver. Check package availability for your kernel and Ubuntu version."
    fi
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    error "nvidia-smi still missing after driver installation"
  fi
}

install_cmpunlocker() {
  info "Cloning cmpunlocker"
  if [ ! -d /tmp/cmpunlocker ]; then
    git clone --branch "$CMPUNLOCKER_TAG" --depth 1 "$CMPUNLOCKER_REPO" /tmp/cmpunlocker
  else
    info "cmpunlocker already present in /tmp/cmpunlocker"
    git -C /tmp/cmpunlocker fetch --tags --depth 1 origin "$CMPUNLOCKER_TAG" || true
    git -C /tmp/cmpunlocker checkout "$CMPUNLOCKER_TAG" || true
  fi

  info "Running cmpunlocker installer"
  cd /tmp/cmpunlocker
  ./install.sh --profile=8gb --no-iommu
}

post_install_checks() {
  info "Checking NVIDIA status"
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    error "nvidia-smi not found after install"
  fi

  nvidia-smi || true

  # Check if GPU memory is large enough for unlocked CMP 170HX.
  total_mem=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -n1 || true)
  if [ -n "${total_mem:-}" ]; then
    info "Detected total memory: ${total_mem}"
    if echo "$total_mem" | grep -Eq '65536|65535|65534'; then
      info "Looks like the cards are unlocked: memory is ~64 GiB per card."
    else
      warn "Memory is below expected ~65536 MiB. The cards may not be unlocked yet."
      warn "Reboot and verify with: nvidia-smi"
    fi
  fi

  if nvidia-smi | grep -qi "ECC Enabled\|ECC enabled"; then
    info "ECC is enabled; this matches the project expectations."
  else
    warn "ECC status is not clearly enabled. This is not necessarily fatal, but verify after reboot."
  fi
}

main() {
  require_root
  check_os
  check_kernel_headers
  check_nvidia_card

  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl git gnupg software-properties-common pciutils dkms

  install_nvidia_repo
  install_open_driver

  info "Reboot is required before running cmpunlocker installation and final verification."
  read -r -p "Do you want to continue with cmpunlocker now? [y/N] " answer || answer="n"
  case "$answer" in
    y|Y|yes|YES)
      install_cmpunlocker
      ;;
    *)
      info "Stopped before cmpunlocker step."
      info "After reboot, run: bash $0"
      exit 0
      ;;
  esac

  info "Disabling passthrough helper if present (per README)"
  systemctl disable cmpunlocker-passthrough.service || true

  post_install_checks

  info "IMPORTANT: power off and back on the machine after this step."
  info "After the reboot, verify with:"
  info "  nvidia-smi"
  info "  nvidia-smi --query-gpu=memory.total --format=csv,noheader"
  info "Expected: ~65536 MiB per card, ECC Enabled"
}

main "$@"
