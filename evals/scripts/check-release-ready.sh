#!/usr/bin/env bash
set -euo pipefail

compare=0

for arg in "$@"; do
  case "$arg" in
    --compare)
      compare=1
      ;;
    -h|--help)
      cat <<'USAGE'
usage: ./evals/scripts/check-release-ready.sh [--compare]

Validates the local release eval environment without printing secret values.
Pass --compare to also validate comparison credentials for all Gateway-backed agents.
USAGE
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "run this script from the fx repository" >&2
  exit 1
fi

cd "$repo_root"

mkdir -p \
  evals/.build/pycache \
  evals/.build/uv-cache \
  evals/.build/uv-tools \
  evals/.build/uv-python

export PYTHONPYCACHEPREFIX="$repo_root/evals/.build/pycache"
export UV_CACHE_DIR="$repo_root/evals/.build/uv-cache"
export UV_TOOL_DIR="$repo_root/evals/.build/uv-tools"
export UV_PYTHON_INSTALL_DIR="$repo_root/evals/.build/uv-python"

failures=0
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fx-release-ready.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

check_step() {
  local label="$1"
  shift
  printf 'checking %s... ' "$label"
  if "$@" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
    printf 'ok\n'
  else
    printf 'failed\n' >&2
    sed 's/^/  /' "$tmp_dir/stderr" >&2
    failures=$((failures + 1))
  fi
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "$name is required" >&2
    return 1
  fi
}

check_fx_credentials() {
  if [ -n "${AI_GATEWAY_API_KEY:-}" ] || [ -n "${VERCEL_OIDC_TOKEN:-}" ]; then
    return 0
  fi
  echo "AI_GATEWAY_API_KEY or VERCEL_OIDC_TOKEN is required for fx evals" >&2
  return 1
}

check_docker_daemon() {
  require_command docker

  local docker_plugin_dir="/opt/homebrew/lib/docker/cli-plugins"
  if [ -d "$docker_plugin_dir" ] && [ -z "${DOCKER_CONFIG:-}" ]; then
    mkdir -p evals/.build/docker-config
    cat > evals/.build/docker-config/config.json <<JSON
{
  "cliPluginsExtraDirs": [
    "$docker_plugin_dir"
  ]
}
JSON
    export DOCKER_CONFIG="$repo_root/evals/.build/docker-config"
  fi

  local colima_socket="$HOME/.colima/default/docker.sock"
  if [ -S "$colima_socket" ] && [ -z "${DOCKER_HOST:-}" ]; then
    export DOCKER_HOST="unix://$colima_socket"
  fi

  docker info >/dev/null
}

check_harbor_cli() {
  if command -v harbor >/dev/null 2>&1; then
    harbor --help >/dev/null
    return 0
  fi
  if command -v uvx >/dev/null 2>&1; then
    uvx harbor --help >/dev/null
    return 0
  fi
  require_command uv
  uv tool run harbor --help >/dev/null
}

check_step "zig" require_command zig
check_step "python3" require_command python3
check_step "Docker daemon" check_docker_daemon
check_step "uv/Harbor" check_harbor_cli
check_step "fx credentials" check_fx_credentials
check_step "job YAML and Harbor JobConfig shape" ./evals/scripts/check-compare-ready.sh --config-only
check_step "publish readiness" ./evals/scripts/check-publish-ready.sh
check_step "RewardKit readiness" ./evals/scripts/check-rewardkit-ready.sh

if [ "$compare" -eq 1 ]; then
  check_step "comparison readiness" ./evals/scripts/check-compare-ready.sh
else
  echo "comparison readiness skipped; pass --compare to validate comparison credentials"
fi

if [ "$failures" -ne 0 ]; then
  echo "release readiness checks failed ($failures failing check(s))" >&2
  exit 1
fi

echo "release readiness checks passed"
