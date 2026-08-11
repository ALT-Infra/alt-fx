#!/usr/bin/env bash
set -u

mkdir -p /logs/verifier

if [ -f /app/command-output.txt ] && [ "$(cat /app/command-output.txt)" = "HELLO_FROM_FX" ]; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
