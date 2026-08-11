#!/usr/bin/env bash
set -u

mkdir -p /logs/verifier

if [ -f /app/hello.txt ] && [ "$(cat /app/hello.txt)" = "Hello, World!" ]; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
