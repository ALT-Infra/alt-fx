#!/usr/bin/env bash
set -euo pipefail

compare=0
multistep=0
full_terminal_bench=0
view=0

for arg in "$@"; do
  case "$arg" in
    --compare)
      compare=1
      ;;
    --multistep)
      multistep=1
      ;;
    --full-terminal-bench)
      full_terminal_bench=1
      ;;
    --view)
      view=1
      ;;
    -h|--help)
      cat <<'USAGE'
usage: ./evals/scripts/run-release-signoff.sh [--multistep] [--compare] [--full-terminal-bench] [--view]

Default signoff:
  1. local fx release evals
  2. Terminal-Bench smoke
  3. Markdown report under evals/runs/

Flags:
  --multistep             also run the local Harbor multi-step smoke
  --compare              also run local and Terminal-Bench comparison smoke jobs
  --full-terminal-bench  run full Terminal-Bench instead of smoke
  --view                 open Harbor viewer after the report is written
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
  evals/.build/uv-tools

export PYTHONPYCACHEPREFIX="$repo_root/evals/.build/pycache"
export UV_CACHE_DIR="$repo_root/evals/.build/uv-cache"
export UV_TOOL_DIR="$repo_root/evals/.build/uv-tools"

if command -v harbor >/dev/null 2>&1; then
  harbor_cmd=(harbor)
elif command -v uvx >/dev/null 2>&1; then
  harbor_cmd=(uvx harbor)
else
  harbor_cmd=(uv tool run harbor)
fi

latest_job_dir() {
  find evals/jobs-out -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
    | sort \
    | tail -n 1
}

run_and_record() {
  local label="$1"
  shift

  echo
  echo "==> $label"
  "$@"

  local job_dir
  job_dir="$(latest_job_dir)"
  if [ -z "$job_dir" ]; then
    echo "no Harbor job directory found after $label" >&2
    exit 1
  fi
  job_dirs+=("$job_dir")
}

print_warning() {
  local message="$1"
  echo "WARNING: $message" >&2
}

if [ "$full_terminal_bench" -eq 1 ]; then
  print_warning "full Terminal-Bench is slow and can cost money. The explicit --full-terminal-bench flag is treated as approval for this run."
fi

if [ "$compare" -eq 1 ]; then
  print_warning "comparison jobs run multiple agents through Vercel AI Gateway. Secrets are validated but not printed."
  if [ "$full_terminal_bench" -eq 1 ]; then
    print_warning "full Terminal-Bench comparison is the slowest, costliest path and requires both --compare and --full-terminal-bench."
  fi
fi

if [ "$compare" -eq 1 ]; then
  ./evals/scripts/check-release-ready.sh --compare
else
  ./evals/scripts/check-release-ready.sh
fi

job_dirs=()

run_and_record "local fx release evals" ./evals/scripts/run-release-evals.sh

if [ "$multistep" -eq 1 ]; then
  run_and_record "local multi-step smoke" ./evals/scripts/run-release-evals.sh --multistep
fi

terminal_args=(--smoke)
terminal_label="Terminal-Bench smoke"
if [ "$full_terminal_bench" -eq 1 ]; then
  terminal_args=(--full)
  terminal_label="full Terminal-Bench"
fi
run_and_record "$terminal_label" ./evals/scripts/run-terminal-bench.sh "${terminal_args[@]}"

if [ "$compare" -eq 1 ]; then
  run_and_record "local comparison evals" ./evals/scripts/run-release-evals.sh --compare

  compare_terminal_args=(--smoke --compare)
  compare_terminal_label="Terminal-Bench comparison smoke"
  if [ "$full_terminal_bench" -eq 1 ]; then
    compare_terminal_args=(--full --compare)
    compare_terminal_label="full Terminal-Bench comparison"
  fi
  run_and_record "$compare_terminal_label" ./evals/scripts/run-terminal-bench.sh "${compare_terminal_args[@]}"
fi

echo
report_path="$(
  python3 evals/scripts/write-run-report.py \
    --title "fx release signoff" \
    --slug "release-signoff" \
    "${job_dirs[@]}"
)"

echo "release signoff report: $report_path"
echo
printf "full Harbor viewer: "
printf "%q " "${harbor_cmd[@]}"
printf "view %q\n" "evals/jobs-out"

if [ "$view" -eq 1 ]; then
  "${harbor_cmd[@]}" view evals/jobs-out
fi
