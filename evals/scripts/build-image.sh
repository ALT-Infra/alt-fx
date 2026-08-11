#!/usr/bin/env bash
set -euo pipefail

binary_only=0
for arg in "$@"; do
  case "$arg" in
    --binary-only)
      binary_only=1
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if ! command -v zig >/dev/null 2>&1; then
  echo "zig is required" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "run this script from the fx repository" >&2
  exit 1
fi

repo_root_real="$(cd "$repo_root" && pwd -P)"
current_dir_real="$(pwd -P)"
if [ "$current_dir_real" != "$repo_root_real" ]; then
  echo "run this script from the fx repository root" >&2
  exit 1
fi

cd "$repo_root_real"

if [ ! -f build.zig ] || [ ! -f src/main.zig ]; then
  echo "run this script from the fx repository root" >&2
  exit 1
fi

if [ "$binary_only" -eq 0 ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required" >&2
    exit 1
  fi

  docker_plugin_dir="/opt/homebrew/lib/docker/cli-plugins"
  if [ -d "$docker_plugin_dir" ] && [ -z "${DOCKER_CONFIG:-}" ]; then
    mkdir -p evals/.build/docker-config
    cat > evals/.build/docker-config/config.json <<JSON
{
  "cliPluginsExtraDirs": [
    "$docker_plugin_dir"
  ]
}
JSON
    export DOCKER_CONFIG="$repo_root_real/evals/.build/docker-config"
  fi

  colima_socket="$HOME/.colima/default/docker.sock"
  if [ -S "$colima_socket" ] && [ -z "${DOCKER_HOST:-}" ]; then
    export DOCKER_HOST="unix://$colima_socket"
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not available; start Docker Desktop or Colima" >&2
    exit 1
  fi
fi

linux_prefix="$repo_root_real/evals/.build/linux"
linux_binary="$linux_prefix/bin/fx"
mkdir -p "$linux_prefix" evals/images

zig build \
  --prefix "$linux_prefix" \
  -Doptimize=ReleaseSafe \
  -Dtarget=x86_64-linux

if [ ! -x "$linux_binary" ]; then
  echo "freshly built Linux fx binary not found at $linux_binary" >&2
  exit 1
fi

install -m 0755 "$linux_binary" evals/images/fx

if [ "$binary_only" -eq 1 ]; then
  exit 0
fi

docker build --platform linux/amd64 -t fx-evals:local -f evals/images/Dockerfile evals/images
