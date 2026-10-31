#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================
# Part 5: launch FlashNext service and verify API availability
# Ubuntu 24.04 + 2x NVIDIA CMP 170HX
# =============================================================

export FLASHNEXT_ROOT="${FLASHNEXT_ROOT:-/opt/flashnext}"

info()  { printf '\n[INFO] %s\n' "$*"; }
warn()  { printf '\n[WARN] %s\n' "$*"; }
error() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

check_env() {
  [ -f "$FLASHNEXT_ROOT/serve.sh" ] || error "Missing launcher: $FLASHNEXT_ROOT/serve.sh"
  [ -d "$FLASHNEXT_ROOT/model-awq-int4ple" ] || error "Missing model directory: $FLASHNEXT_ROOT/model-awq-int4ple"
  [ -d "$FLASHNEXT_ROOT/vllm-backport/.venv" ] || error "Missing venv: $FLASHNEXT_ROOT/vllm-backport/.venv"

  if ! command -v curl >/dev/null 2>&1; then
    apt-get install -y curl
  fi
}

start_server() {
  info "Starting FlashNext server"
  nohup bash "$FLASHNEXT_ROOT/serve.sh" > "$FLASHNEXT_ROOT/flashnext.log" 2>&1 &
  echo $! > "$FLASHNEXT_ROOT/flashnext.pid"
  sleep 15
}

wait_for_api() {
  for i in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:18084/health >/tmp/flashnext_health.txt 2>/dev/null; then
      info "Server is responding on http://127.0.0.1:18084"
      cat /tmp/flashnext_health.txt
      return 0
    fi
    sleep 2
  done
  error "Server did not become healthy within 120 seconds. Check log: $FLASHNEXT_ROOT/flashnext.log"
}

smoke_test() {
  local payload='{"model":"tinybeast-flashnext-uncensored","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":32,"temperature":0.0}'

  info "Sending a smoke test request"
  curl -fsS -X POST http://127.0.0.1:18084/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "$payload" | head -c 800
}

main() {
  require_command bash
  require_command curl
  check_env
  start_server
  wait_for_api
  smoke_test
  info "Done. The model server is running on 127.0.0.1:18084"
  info "Logs: $FLASHNEXT_ROOT/flashnext.log"
  info "PID: $(cat "$FLASHNEXT_ROOT/flashnext.pid")"
}

main "$@"
