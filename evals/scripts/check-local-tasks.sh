#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "run this script from the fx repository" >&2
  exit 1
fi

cd "$repo_root"

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
  export DOCKER_CONFIG="$repo_root/evals/.build/docker-config"
fi

colima_socket="$HOME/.colima/default/docker.sock"
if [ -S "$colima_socket" ] && [ -z "${DOCKER_HOST:-}" ]; then
  export DOCKER_HOST="unix://$colima_socket"
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not available; start Docker Desktop or Colima" >&2
  exit 1
fi

if ! docker image inspect fx-evals:local >/dev/null 2>&1; then
  echo "fx-evals:local image is required; run ./evals/scripts/build-image.sh first" >&2
  exit 1
fi

safe_tag() {
  local name="$1"
  name="${name//[^a-zA-Z0-9_.-]/-}"
  printf 'fx-task-check:%s\n' "$name"
}

build_task_image() {
  local task_dir="$1"
  local name="$2"
  local tag
  tag="$(safe_tag "$name")"

  docker build \
    --platform linux/amd64 \
    -t "$tag" \
    -f "$task_dir/environment/Dockerfile" \
    "$task_dir/environment" \
    >/dev/null

  printf '%s\n' "$tag"
}

check_single_step_task() {
  local task_dir="$1"
  local task_name
  local task_abs
  local image

  task_name="$(basename "$task_dir")"
  task_abs="$(cd "$task_dir" && pwd -P)"
  printf 'checking %s\n' "$task_name"
  image="$(build_task_image "$task_abs" "release-$task_name")"

  docker run --rm \
    --platform linux/amd64 \
    -v "$task_abs/solution:/solution:ro" \
    -v "$task_abs/tests:/tests:ro" \
    "$image" \
    bash -lc '
      set -u
      rm -rf /logs/verifier
      mkdir -p /logs/verifier
      bash /solution/solve.sh
      bash /tests/test.sh
      reward=""
      if [ -f /logs/verifier/reward.txt ]; then
        reward="$(cat /logs/verifier/reward.txt)"
      fi
      case "$reward" in
        1|1.0) exit 0 ;;
        *)
          echo "reward=$reward" >&2
          find /logs/verifier -maxdepth 1 -type f -print >&2
          exit 1
          ;;
      esac
    '
}

check_multistep_task() {
  local task_dir="$1"
  shift
  local task_name
  local task_abs
  local image

  task_name="$(basename "$task_dir")"
  task_abs="$(cd "$task_dir" && pwd -P)"
  printf 'checking %s\n' "$task_name"
  image="$(build_task_image "$task_abs" "multistep-$task_name")"

  docker run --rm \
    --platform linux/amd64 \
    -v "$task_abs/steps:/task/steps:ro" \
    "$image" \
    bash -lc '
      set -u
      for step in "$@"; do
        rm -rf /logs/verifier
        mkdir -p /logs/verifier
        bash "/task/steps/$step/solution/solve.sh"
        bash "/task/steps/$step/tests/test.sh"
        reward=""
        if [ -f /logs/verifier/reward.txt ]; then
          reward="$(cat /logs/verifier/reward.txt)"
        fi
        case "$reward" in
          1|1.0) ;;
          *)
            echo "$step reward=$reward" >&2
            find /logs/verifier -maxdepth 1 -type f -print >&2
            exit 1
            ;;
        esac
      done
    ' check-local-tasks "$@"
}

for task_dir in evals/datasets/fx-release/*; do
  if [ -f "$task_dir/task.toml" ]; then
    check_single_step_task "$task_dir"
  fi
done

check_multistep_task \
  evals/datasets/fx-multistep/stateful-report \
  seed-report \
  extend-report

echo "all local task solutions produced reward 1"
