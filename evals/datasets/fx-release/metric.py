#!/usr/bin/env python3
# /// script
# dependencies = []
# ///
from __future__ import annotations

import runpy
from pathlib import Path


SHARED_METRIC = Path(__file__).resolve().parents[2] / "metrics" / "fx_metrics.py"

if not SHARED_METRIC.exists():
    raise SystemExit(f"shared fx metric script not found: {SHARED_METRIC}")
runpy.run_path(str(SHARED_METRIC), run_name="__main__")
