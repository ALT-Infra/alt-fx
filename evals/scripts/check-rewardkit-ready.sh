#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "run this script from the fx repository" >&2
  exit 1
fi

cd "$repo_root"

mkdir -p evals/.build/pycache
export PYTHONPYCACHEPREFIX="$repo_root/evals/.build/pycache"

python3 evals/scripts/check-rewardkit-ready.py
