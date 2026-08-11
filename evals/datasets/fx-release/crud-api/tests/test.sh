#!/usr/bin/env bash
set -u

mkdir -p /logs/verifier
cd /app || {
  echo 0 > /logs/verifier/reward.txt
  exit 0
}

if [ ! -f /app/package.json ]; then
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi

if ! grep -R "express" /app --include='*.ts' --include='*.js' > /logs/verifier/express-grep.txt 2>&1; then
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi

if ! grep -R "todos" /app --include='*.ts' --include='*.js' > /logs/verifier/todos-grep.txt 2>&1; then
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi

if npm install > /logs/verifier/npm-install.txt 2>&1 \
  && npm test > /logs/verifier/npm-test.txt 2>&1; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
