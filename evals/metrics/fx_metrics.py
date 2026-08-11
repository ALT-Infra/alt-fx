#!/usr/bin/env python3
# /// script
# dependencies = []
# ///
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def reward_value(reward: Any) -> float:
    if reward is None:
        return 0.0
    if isinstance(reward, bool):
        return float(reward)
    if isinstance(reward, (int, float)):
        return float(reward)
    if isinstance(reward, dict):
        if not reward:
            return 0.0
        return max(reward_value(item) for item in reward.values())
    return 0.0


def read_rewards(input_path: Path) -> list[float]:
    rewards: list[float] = []
    for line in input_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rewards.append(reward_value(json.loads(line)))
    return rewards


def metric_values(rewards: list[float]) -> dict[str, float | int]:
    n_trials = len(rewards)
    n_passed = sum(1 for reward in rewards if reward >= 1.0)
    return {
        "mean_reward": sum(rewards) / n_trials if n_trials else 0.0,
        "pass_rate": n_passed / n_trials if n_trials else 0.0,
        "n_trials": n_trials,
        "n_passed": n_passed,
    }


def main(input_path: Path, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(metric_values(read_rewards(input_path)), sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-i",
        "--input-path",
        type=Path,
        required=True,
        help="Path to a JSONL file containing one reward value per trial.",
    )
    parser.add_argument(
        "-o",
        "--output-path",
        type=Path,
        required=True,
        help="Path to the JSON object Harbor should read as job metrics.",
    )
    args = parser.parse_args()
    main(args.input_path, args.output_path)
