#!/bin/bash
set -e

echo "=== zig build ==="
zig build

echo "=== zig build test ==="
zig build test

echo "=== Cleanup ==="
rm -rf .zig-cache zig-cache zig-out

echo "=== All Linux checks passed ==="
