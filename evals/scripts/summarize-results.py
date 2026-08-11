#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


AGENT_IMPORT_NAMES = {
    "evals.agents.fx_agent:FxAgent": "fx",
    "evals.agents.codex_gateway:CodexGatewayAgent": "codex",
    "evals.agents.claude_gateway:ClaudeCodeGatewayAgent": "claude-code",
    "evals.agents.opencode_gateway:OpenCodeGatewayAgent": "opencode",
}


@dataclass
class Trial:
    task: str
    agent: str
    model: str | None
    reward: float | None
    source: str | None
    exception: str | None
    artifact_manifest_found: bool
    artifact_failures: tuple[str, ...]

    @property
    def reward_value(self) -> float:
        return self.reward if self.reward is not None else 0.0

    @property
    def passed(self) -> bool:
        return self.exception is None and self.reward_value >= 1.0


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def find_latest_job(path: Path) -> Path:
    if (path / "result.json").exists() or (path / "config.json").exists():
        return path

    candidates = [
        child
        for child in path.iterdir()
        if child.is_dir()
        and ((child / "result.json").exists() or (child / "config.json").exists())
    ]
    if not candidates:
        raise SystemExit(f"no Harbor job found under {path}")
    return max(candidates, key=lambda item: item.stat().st_mtime)


def find_key(value: Any, names: set[str]) -> Any:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in names:
                return item
        for item in value.values():
            found = find_key(item, names)
            if found is not None:
                return found
    elif isinstance(value, list):
        for item in value:
            found = find_key(item, names)
            if found is not None:
                return found
    return None


def name_from_value(value: Any) -> str | None:
    if isinstance(value, str):
        return value.split("/")[-1]
    if isinstance(value, dict):
        for key in ("name", "task_name", "path"):
            item = value.get(key)
            if isinstance(item, str):
                return item.split("/")[-1]
    return None


def string_from_value(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("source", "name", "path"):
            item = value.get(key)
            if isinstance(item, str):
                return item
    return None


def agent_info_name(result: Any) -> str | None:
    if not isinstance(result, dict):
        return None
    agent_info = result.get("agent_info")
    if not isinstance(agent_info, dict):
        return None
    name = agent_info.get("name")
    return name if isinstance(name, str) and name else None


def agent_info_model(result: Any) -> str | None:
    if not isinstance(result, dict):
        return None
    agent_info = result.get("agent_info")
    if not isinstance(agent_info, dict):
        return None
    model_info = agent_info.get("model_info")
    if not isinstance(model_info, dict):
        return None
    name = model_info.get("name")
    provider = model_info.get("provider")
    if not isinstance(name, str) or not name:
        return None
    if isinstance(provider, str) and provider:
        return f"{provider}/{name}"
    return name


def config_agent_name(config: Any) -> str | None:
    if not isinstance(config, dict):
        return None
    agent = config.get("agent")
    if not isinstance(agent, dict):
        return None
    import_path = agent.get("import_path")
    if isinstance(import_path, str) and import_path in AGENT_IMPORT_NAMES:
        return AGENT_IMPORT_NAMES[import_path]
    name = agent.get("name")
    return name if isinstance(name, str) and name else None


def read_reward(trial_dir: Path, result: Any) -> float | None:
    reward_txt = trial_dir / "verifier" / "reward.txt"
    if reward_txt.exists():
        try:
            return float(reward_txt.read_text(encoding="utf-8").strip())
        except ValueError:
            return 0.0

    reward_json = trial_dir / "verifier" / "reward.json"
    if reward_json.exists():
        value = load_json(reward_json)
        if isinstance(value, dict) and value:
            try:
                return max(float(item) for item in value.values())
            except (TypeError, ValueError):
                return 0.0

    found = find_key(result, {"reward", "rewards"})
    if isinstance(found, (int, float)):
        return float(found)
    if isinstance(found, dict) and found:
        try:
            return max(float(item) for item in found.values())
        except (TypeError, ValueError):
            return 0.0
    return None


def read_exception(trial_dir: Path, result: Any) -> str | None:
    exception_txt = trial_dir / "exception.txt"
    if exception_txt.exists():
        text = exception_txt.read_text(encoding="utf-8", errors="replace").strip()
        if text:
            lines = [line.strip() for line in text.splitlines() if line.strip()]
            for line in reversed(lines):
                if line.startswith(("Traceback ", "File ", "...<")):
                    continue
                if re.match(
                    r"^([A-Za-z_][\w.]*\.)*[A-Za-z_]\w*(Error|Exception)(:|$)",
                    line,
                ):
                    return line[:240]
            return lines[0][:240]

    exception_info = find_key(result, {"exception_info"})
    if isinstance(exception_info, dict):
        message = exception_info.get("message") or exception_info.get("error")
        exc_type = exception_info.get("type") or exception_info.get("exception_type")
        if exc_type and message:
            return f"{exc_type}: {message}"[:240]
        if message:
            return str(message)[:240]
        if exc_type:
            return str(exc_type)[:240]
    if isinstance(exception_info, str) and exception_info.strip():
        return exception_info.strip()[:240]
    return None


def read_artifact_status(trial_dir: Path) -> tuple[bool, tuple[str, ...]]:
    manifest_paths = [trial_dir / "artifacts" / "manifest.json"]
    steps_dir = trial_dir / "steps"
    if steps_dir.exists():
        manifest_paths.extend(
            sorted(steps_dir.glob("*/artifacts/manifest.json"))
        )

    failures: list[str] = []
    found = False
    for manifest_path in manifest_paths:
        if not manifest_path.exists():
            continue
        found = True
        label = manifest_path.relative_to(trial_dir).as_posix()

        manifest = load_json(manifest_path)
        if not isinstance(manifest, list):
            failures.append(f"{label}: manifest is not a JSON array")
            continue

        for entry in manifest:
            if not isinstance(entry, dict):
                failures.append(f"{label}: manifest entry is not an object")
                continue

            status = str(entry.get("status") or "unknown")
            if status.lower() == "ok":
                continue

            source = str(entry.get("source") or "unknown")
            destination = str(entry.get("destination") or "unknown")
            detail = f"{label}: {source} -> {destination}: {status}"
            message = entry.get("error") or entry.get("message")
            if message:
                detail = f"{detail} ({message})"
            failures.append(detail[:240])

    return found, tuple(failures)


def read_trials(job_dir: Path) -> list[Trial]:
    trials: list[Trial] = []
    for child in sorted(job_dir.iterdir()):
        if not child.is_dir():
            continue
        result = load_json(child / "result.json")
        config = load_json(child / "config.json")
        if result is None and config is None and not (child / "exception.txt").exists():
            continue
        reward = read_reward(child, result)

        task = (
            name_from_value(find_key(config, {"task_name", "task"}))
            or name_from_value(find_key(result, {"task_name", "task"}))
            or child.name
        )
        agent = (
            agent_info_name(result)
            or config_agent_name(config)
            or name_from_value(find_key(config, {"agent_name", "agent"}))
            or "unknown"
        )
        model = agent_info_model(result) or string_from_value(
            find_key(config, {"model_name"})
        )
        source = (
            string_from_value(find_key(config, {"source"}))
            or string_from_value(find_key(result, {"source"}))
        )
        artifact_manifest_found, artifact_failures = read_artifact_status(child)
        trials.append(
            Trial(
                task=task,
                agent=agent,
                model=model,
                reward=reward,
                source=source,
                exception=read_exception(child, result),
                artifact_manifest_found=artifact_manifest_found,
                artifact_failures=artifact_failures,
            )
        )
    return trials


def primary_agent(trials: list[Trial]) -> str:
    agents = sorted({trial.agent for trial in trials})
    if "fx" in agents:
        return "fx"
    return agents[0] if agents else "fx"


def dataset_label(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None
    name = value.get("name")
    if isinstance(name, str) and name:
        return name
    path = value.get("path")
    if isinstance(path, str) and path:
        return Path(path).name
    return None


def unique_labels(values: list[str]) -> list[str]:
    seen: set[str] = set()
    labels: list[str] = []
    for value in values:
        if value and value not in seen:
            labels.append(value)
            seen.add(value)
    return labels


def infer_dataset(job_config: Any, trials: list[Trial]) -> str:
    labels: list[str] = []
    if isinstance(job_config, dict):
        datasets = job_config.get("datasets")
        if isinstance(datasets, list):
            labels.extend(label for item in datasets if (label := dataset_label(item)))

    labels.extend(trial.source for trial in trials if trial.source)
    labels = unique_labels(labels)
    if labels:
        return ", ".join(labels)
    return "unknown"


def group_stats(trials: list[Trial]) -> tuple[int, int, float, float, int, int]:
    total = len(trials)
    passed = sum(1 for trial in trials if trial.passed)
    reward_sum = sum(trial.reward_value for trial in trials)
    mean_reward = reward_sum / total if total else 0.0
    pass_rate = passed / total if total else 0.0
    exceptions = sum(1 for trial in trials if trial.exception is not None)
    artifact_failures = sum(len(trial.artifact_failures) for trial in trials)
    return total, passed, pass_rate, mean_reward, exceptions, artifact_failures


def job_error_count(job_result: Any) -> int | None:
    if not isinstance(job_result, dict):
        return None
    stats = job_result.get("stats")
    if not isinstance(stats, dict):
        return None
    value = stats.get("n_errored_trials")
    return value if isinstance(value, int) else None


def job_total_count(job_result: Any) -> int | None:
    if not isinstance(job_result, dict):
        return None
    value = job_result.get("n_total_trials")
    return value if isinstance(value, int) else None


MetricMap = dict[str, Any]

METRIC_ORDER = ("mean_reward", "pass_rate", "n_trials", "n_passed", "mean")


def job_metrics_by_eval(job_result: Any) -> dict[str, MetricMap]:
    if not isinstance(job_result, dict):
        return {}
    stats = job_result.get("stats")
    if not isinstance(stats, dict):
        return {}
    evals = stats.get("evals")
    if not isinstance(evals, dict):
        return {}

    metrics_by_eval: dict[str, MetricMap] = {}
    for eval_name, eval_result in evals.items():
        if not isinstance(eval_name, str) or not isinstance(eval_result, dict):
            continue
        metric_items = eval_result.get("metrics")
        if not isinstance(metric_items, list):
            continue
        merged: MetricMap = {}
        for item in metric_items:
            if not isinstance(item, dict):
                continue
            for key, value in item.items():
                if isinstance(key, str) and isinstance(value, (int, float)):
                    merged[key] = value
        if merged:
            metrics_by_eval[eval_name] = merged
    return metrics_by_eval


def metrics_for_agent(metrics_by_eval: dict[str, MetricMap], agent: str) -> MetricMap | None:
    matches = [
        metrics
        for eval_name, metrics in metrics_by_eval.items()
        if eval_name.split("__", 1)[0] == agent
    ]
    if len(matches) == 1:
        return matches[0]
    if not matches and len(metrics_by_eval) == 1:
        return next(iter(metrics_by_eval.values()))
    return None


def metric_sort_key(key: str) -> tuple[int, str]:
    try:
        return (METRIC_ORDER.index(key), key)
    except ValueError:
        return (len(METRIC_ORDER), key)


def format_metric_value(key: str, value: int | float) -> str:
    if key.startswith("n_") and float(value).is_integer():
        return str(int(value))
    return f"{float(value):.2f}"


def format_metrics(metrics: MetricMap) -> str:
    return " ".join(
        f"{key}={format_metric_value(key, metrics[key])}"
        for key in sorted(metrics, key=metric_sort_key)
    )


def print_summary(job_dir: Path, trials: list[Trial]) -> None:
    if not trials:
        raise SystemExit(f"no Harbor trials found under {job_dir}")

    job_config = load_json(job_dir / "config.json")
    job_result = load_json(job_dir / "result.json")
    dataset = infer_dataset(job_config, trials)
    agent = primary_agent(trials)
    primary = [trial for trial in trials if trial.agent == agent]
    (
        total,
        passed,
        pass_rate,
        mean_reward,
        exceptions_count,
        artifact_failure_count,
    ) = group_stats(primary)
    job_errors = job_error_count(job_result)
    job_total = job_total_count(job_result)
    error_count = job_errors if job_errors is not None else exceptions_count
    metrics_by_eval = job_metrics_by_eval(job_result)
    primary_metrics = metrics_for_agent(metrics_by_eval, agent)

    title = "fx release evals" if dataset == "fx-release" else "Harbor evals"
    print(title)
    print()
    print(f"dataset: {dataset}")
    print(f"agent: {agent}")
    if (
        job_total is not None
        and job_total != total
        and len({trial.agent for trial in trials}) == 1
    ):
        print(f"trials: {total}/{job_total}")
    else:
        print(f"trials: {total}")
    print(f"n_trials: {total}")
    print(f"n_passed: {passed}")
    print(f"pass_rate: {pass_rate:.2f}")
    print(f"mean_reward: {mean_reward:.2f}")
    print(f"errors: {error_count}")
    print(f"exceptions: {exceptions_count}")
    print(f"artifact_failures: {artifact_failure_count}")
    if primary_metrics:
        print(f"harbor_metrics: {format_metrics(primary_metrics)}")
    print()

    failed = [trial for trial in primary if not trial.passed]
    print("failed tasks:")
    if failed:
        for trial in failed:
            reward = trial.reward_value
            print(f"- {trial.task} ({reward:.2f})")
    else:
        print("- none")

    exceptions = [trial for trial in primary if trial.exception]
    print()
    print("errors/exceptions:")
    if exceptions:
        for trial in exceptions:
            print(f"- {trial.task}: {trial.exception}")
    else:
        print("- none")

    artifact_failures = [
        (trial, failure)
        for trial in trials
        for failure in trial.artifact_failures
    ]
    artifact_manifest_count = sum(1 for trial in trials if trial.artifact_manifest_found)
    print()
    print("artifact collection:")
    if artifact_failures:
        for trial, failure in artifact_failures:
            print(f"- {trial.agent}/{trial.task}: {failure}")
    elif artifact_manifest_count:
        print("- failures: 0")
    else:
        print("- no manifests found")

    agents = sorted({trial.agent for trial in trials})
    if len(agents) > 1:
        print()
        print("per-agent summary:")
        print(
            f"{'agent':<14} {'n_trials':>8} {'n_passed':>8} "
            f"{'pass_rate':>9} {'mean_reward':>11} "
            f"{'exceptions':>10} {'artifact_failures':>18}"
        )
        for name in agents:
            group = [trial for trial in trials if trial.agent == name]
            (
                group_total,
                passed,
                group_pass_rate,
                group_mean_reward,
                group_exceptions,
                group_artifact_failures,
            ) = group_stats(group)
            print(
                f"{name:<14} {group_total:>8} {passed:>8} "
                f"{group_pass_rate:>9.2f} {group_mean_reward:>11.2f} "
                f"{group_exceptions:>10} {group_artifact_failures:>18}"
            )

        if metrics_by_eval:
            print()
            print("harbor metrics by agent:")
            for name in agents:
                agent_metrics = metrics_for_agent(metrics_by_eval, name)
                if agent_metrics:
                    print(f"- {name}: {format_metrics(agent_metrics)}")

    print()
    print("full results:")
    print(job_dir)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", default="evals/jobs-out")
    args = parser.parse_args()

    root = Path(args.path)
    job_dir = find_latest_job(root)
    print_summary(job_dir, read_trials(job_dir))


if __name__ == "__main__":
    main()
