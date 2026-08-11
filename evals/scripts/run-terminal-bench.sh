#!/usr/bin/env bash
set -euo pipefail

mode="smoke"
compare=0
view=0
non_view_args=0

for arg in "$@"; do
  case "$arg" in
    --smoke)
      mode="smoke"
      non_view_args=1
      ;;
    --full)
      mode="full"
      non_view_args=1
      ;;
    --compare)
      compare=1
      non_view_args=1
      ;;
    --view)
      view=1
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

mkdir -p \
  evals/.build/harbor-datasets \
  evals/.build/pycache \
  evals/.build/uv-cache \
  evals/.build/uv-tools

export PYTHONPYCACHEPREFIX="$repo_root/evals/.build/pycache"
export UV_CACHE_DIR="$repo_root/evals/.build/uv-cache"
export UV_TOOL_DIR="$repo_root/evals/.build/uv-tools"

if command -v harbor >/dev/null 2>&1; then
  harbor_cmd=(harbor)
elif command -v uvx >/dev/null 2>&1; then
  harbor_cmd=(uvx harbor)
else
  require_command uv
  harbor_cmd=(uv tool run harbor)
fi

print_viewer_command() {
  printf "full Harbor viewer: "
  printf "%q " "${harbor_cmd[@]}"
  printf "view %q\n" "evals/jobs-out"
}

run_job=1
if [ "$view" -eq 1 ] && [ "$non_view_args" -eq 0 ]; then
  run_job=0
fi

if [ "$run_job" -eq 1 ]; then
  if [ "$mode" = "full" ]; then
    echo "WARNING: full Terminal-Bench is slow and can cost money. The explicit --full flag is treated as approval for this run." >&2
    if [ "$compare" -eq 1 ]; then
      echo "WARNING: full Terminal-Bench comparison runs multiple agents and is the slowest, costliest path." >&2
    fi
  fi

  require_command zig
  require_command docker
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

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not available; start Docker Desktop or Colima" >&2
    exit 1
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

  ./evals/scripts/build-image.sh --binary-only

  mkdir -p evals/jobs-out
  export PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}"

  if [ "$compare" -eq 1 ] && [ "$mode" = "full" ]; then
    job_config="evals/jobs/compare-terminal-bench.yaml"
  elif [ "$compare" -eq 1 ]; then
    job_config="evals/jobs/compare-terminal-bench-smoke.yaml"
  elif [ "$mode" = "full" ]; then
    job_config="evals/jobs/fx-terminal-bench.yaml"
  else
    job_config="evals/jobs/fx-terminal-bench-smoke.yaml"
  fi

  "${harbor_cmd[@]}" run -c "$job_config"

  python3 evals/scripts/summarize-results.py evals/jobs-out
  echo
  print_viewer_command
fi

if [ "$view" -eq 1 ]; then
  if [ "$run_job" -eq 0 ]; then
    print_viewer_command
  fi
  "${harbor_cmd[@]}" view evals/jobs-out
fi
