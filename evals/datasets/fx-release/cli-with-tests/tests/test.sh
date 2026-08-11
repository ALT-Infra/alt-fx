#!/usr/bin/env bash
set -u

mkdir -p /logs/verifier

project_dir=""
if [ -f /app/package.json ]; then
  project_dir="/app"
else
  candidates=()
  for child in /app/*; do
    if [ -d "$child" ] && [ -f "$child/package.json" ]; then
      candidates+=("$child")
    fi
  done

  if [ "${#candidates[@]}" -eq 1 ]; then
    project_dir="${candidates[0]}"
  fi
fi

if [ -z "$project_dir" ]; then
  echo "no package.json at /app and no single child project with package.json" \
    > /logs/verifier/project-dir.txt
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi

printf '%s\n' "$project_dir" > /logs/verifier/project-dir.txt

if [ ! -f "$project_dir/package.json" ]; then
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi

if ! find "$project_dir" -maxdepth 4 -type f | grep -Eq '(wordcount|cli|index)\.(js|ts)$'; then
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi

if cd "$project_dir" \
  && npm install > /logs/verifier/npm-install.txt 2>&1 \
  && npm test > /logs/verifier/npm-test.txt 2>&1; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
