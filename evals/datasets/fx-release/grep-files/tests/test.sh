#!/usr/bin/env bash
set -u

mkdir -p /logs/verifier

if [ -f /app/found-file.txt ] && grep -Eq '(^|/)auth\.ts$' /app/found-file.txt; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
