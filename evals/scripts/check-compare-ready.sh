#!/usr/bin/env bash
set -euo pipefail

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

if python3 -c 'import harbor.models.job.config' >/dev/null 2>&1; then
  python3 evals/scripts/check-compare-ready.py "$@"
else
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required when Harbor is not importable by python3" >&2
    exit 1
  fi
  uv run --quiet --python 3.12 --with harbor python evals/scripts/check-compare-ready.py "$@"
fi
