#!/usr/bin/env bash
set -euo pipefail

compare=0
multistep=0
for arg in "$@"; do
  case "$arg" in
    --compare)
      compare=1
      ;;
    --multistep)
      multistep=1
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if [ "$compare" -eq 1 ] && [ "$multistep" -eq 1 ]; then
  echo "--compare and --multistep cannot be combined" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "run this script from the fx repository" >&2
  exit 1
fi

cd "$repo_root"

mkdir -p \
  evals/.build/pycache \
  evals/.build/uv-cache \
  evals/.build/uv-tools

export PYTHONPYCACHEPREFIX="$repo_root/evals/.build/pycache"
export UV_CACHE_DIR="$repo_root/evals/.build/uv-cache"
export UV_TOOL_DIR="$repo_root/evals/.build/uv-tools"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

require_command zig
require_command docker
require_command uv
require_command python3

docker_plugin_dir="/opt/homebrew/lib/docker/cli-plugins"
if [ -d "$docker_plugin_dir" ]; then
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

colima_socket="$HOME/.colima/default/docker.sock"
if [ -S "$colima_socket" ]; then
  export DOCKER_HOST="unix://$colima_socket"
fi

if [ -z "${AI_GATEWAY_API_KEY:-}" ] && [ -z "${VERCEL_OIDC_TOKEN:-}" ]; then
  echo "AI_GATEWAY_API_KEY or VERCEL_OIDC_TOKEN is required for fx" >&2
  exit 1
fi

export AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-}"
export VERCEL_OIDC_TOKEN="${VERCEL_OIDC_TOKEN:-}"

if [ "$compare" -eq 1 ]; then
  ./evals/scripts/check-compare-ready.sh

  export ANTHROPIC_BASE_URL="https://ai-gateway.vercel.sh"
  export ANTHROPIC_AUTH_TOKEN="$AI_GATEWAY_API_KEY"
  export ANTHROPIC_API_KEY=""
  export OPENAI_API_KEY=""
  export OPENAI_BASE_URL=""
fi

if command -v harbor >/dev/null 2>&1; then
  harbor_cmd=(harbor)
elif command -v uvx >/dev/null 2>&1; then
  harbor_cmd=(uvx harbor)
else
  harbor_cmd=(uv tool run harbor)
fi

./evals/scripts/build-image.sh

mkdir -p evals/jobs-out
export PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}"

if [ "$compare" -eq 1 ]; then
  job_config="evals/jobs/compare-key-agents.yaml"
elif [ "$multistep" -eq 1 ]; then
  job_config="evals/jobs/fx-multistep.yaml"
else
  job_config="evals/jobs/fx-release.yaml"
fi

"${harbor_cmd[@]}" run -c "$job_config"

python3 evals/scripts/summarize-results.py evals/jobs-out

echo
echo "full Harbor viewer:"
echo "harbor view evals/jobs-out"
