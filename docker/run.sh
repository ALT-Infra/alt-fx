#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

cd "$ROOT"
docker build --platform linux/amd64 -t fx-linux -f docker/Dockerfile .
docker run --rm --platform linux/amd64 -v "$ROOT:/fx" fx-linux bash docker/test.sh
