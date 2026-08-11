#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import re
import shlex
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNS_DIR = REPO_ROOT / "evals" / "runs"
RUNS_INDEX = RUNS_DIR / "RUNS.md"
sys.dont_write_bytecode = True


def load_summary_module() -> Any:
    path = Path(__file__).with_name("summarize-results.py")
    spec = importlib.util.spec_from_file_location("fx_summarize_results", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


SUMMARY = load_summary_module()


@dataclass
class AgentStats:
    agent: str
    model: str
    n_trials: int
    n_passed: int
    pass_rate: float
    mean_reward: float
    exceptions: int
    artifact_failures: int


@dataclass
class JobReport:
    path: Path
    dataset: str
    agents: list[AgentStats]
    exceptions: list[str]
    artifact_failures: list[str]
    started_at: str | None
    finished_at: str | None


def rel(path: Path) -> str:
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "harbor-run"


def model_for_agent(job_config: Any, agent: str) -> str:
    if not isinstance(job_config, dict):
        return "unknown"
    agents = job_config.get("agents")
    if not isinstance(agents, list):
        return "unknown"
    for item in agents:
        if not isinstance(item, dict):
            continue
        if item.get("name") != agent:
            continue
        model = item.get("model_name")
        return model if isinstance(model, str) and model else "unknown"
    return "unknown"


def agent_stats(job_config: Any, trials: list[Any]) -> list[AgentStats]:
    stats: list[AgentStats] = []
    for agent in sorted({trial.agent for trial in trials}):
        group = [trial for trial in trials if trial.agent == agent]
        (
            n_trials,
            n_passed,
            pass_rate,
            mean_reward,
            exceptions,
            artifact_failures,
        ) = SUMMARY.group_stats(group)
        stats.append(
            AgentStats(
                agent=agent,
                model=next(
                    (trial.model for trial in group if getattr(trial, "model", None)),
                    None,
                )
                or model_for_agent(job_config, agent),
                n_trials=n_trials,
                n_passed=n_passed,
                pass_rate=pass_rate,
                mean_reward=mean_reward,
                exceptions=exceptions,
                artifact_failures=artifact_failures,
            )
        )
    return stats


def read_job(path: Path) -> JobReport:
    job_dir = SUMMARY.find_latest_job(path)
    trials = SUMMARY.read_trials(job_dir)
    if not trials:
        raise SystemExit(f"no Harbor trials found under {job_dir}")

    job_config = SUMMARY.load_json(job_dir / "config.json")
    job_result = SUMMARY.load_json(job_dir / "result.json")
    dataset = SUMMARY.infer_dataset(job_config, trials)

    exceptions = [
        f"{trial.agent}/{trial.task}: {trial.exception}"
        for trial in trials
        if trial.exception
    ]
    artifact_failures = [
        f"{trial.agent}/{trial.task}: {failure}"
        for trial in trials
        for failure in trial.artifact_failures
    ]

    started_at = None
    finished_at = None
    if isinstance(job_result, dict):
        started = job_result.get("started_at")
        finished = job_result.get("finished_at")
        if isinstance(started, str):
            started_at = started
        if isinstance(finished, str):
            finished_at = finished

    return JobReport(
        path=job_dir,
        dataset=dataset,
        agents=agent_stats(job_config, trials),
        exceptions=exceptions,
        artifact_failures=artifact_failures,
        started_at=started_at,
        finished_at=finished_at,
    )


def format_float(value: float) -> str:
    return f"{value:.2f}"


def table_row(values: list[str]) -> str:
    return "| " + " | ".join(values) + " |"


def harbor_view_command() -> str:
    if shutil.which("harbor"):
        return "harbor view evals/jobs-out"
    if shutil.which("uvx"):
        return "uvx harbor view evals/jobs-out"
    return shlex.join(["uv", "tool", "run", "harbor", "view", "evals/jobs-out"])


def job_section(job: JobReport) -> list[str]:
    lines: list[str] = []
    lines.append(f"## {job.dataset}")
    lines.append("")
    lines.append(f"- Result path: `{rel(job.path)}`")
    if job.started_at:
        lines.append(f"- Started: `{job.started_at}`")
    if job.finished_at:
        lines.append(f"- Finished: `{job.finished_at}`")
    lines.append("")
    lines.append(
        table_row(
            [
                "Agent",
                "Model",
                "n_trials",
                "n_passed",
                "pass_rate",
                "mean_reward",
                "exceptions",
                "artifact failures",
            ]
        )
    )
    lines.append(table_row(["---", "---", "---:", "---:", "---:", "---:", "---:", "---:"]))
    for stats in job.agents:
        lines.append(
            table_row(
                [
                    f"`{stats.agent}`",
                    f"`{stats.model}`",
                    str(stats.n_trials),
                    str(stats.n_passed),
                    format_float(stats.pass_rate),
                    format_float(stats.mean_reward),
                    str(stats.exceptions),
                    str(stats.artifact_failures),
                ]
            )
        )

    lines.append("")
    lines.append("Exceptions:")
    if job.exceptions:
        lines.extend(f"- {item}" for item in job.exceptions)
    else:
        lines.append("- none")

    lines.append("")
    lines.append("Artifact failures:")
    if job.artifact_failures:
        lines.extend(f"- {item}" for item in job.artifact_failures)
    else:
        lines.append("- none")

    lines.append("")
    return lines


def report_lines(title: str, jobs: list[JobReport]) -> list[str]:
    today = datetime.now().strftime("%Y-%m-%d")
    lines = [f"# {today} {title}", ""]
    lines.append("Viewer command:")
    lines.append("")
    lines.append("```bash")
    lines.append(harbor_view_command())
    lines.append("```")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(
        table_row(
            [
                "Dataset",
                "Agent",
                "Model",
                "n_trials",
                "n_passed",
                "pass_rate",
                "mean_reward",
                "exceptions",
                "artifact failures",
                "Result path",
            ]
        )
    )
    lines.append(
        table_row(["---", "---", "---", "---:", "---:", "---:", "---:", "---:", "---:", "---"])
    )
    for job in jobs:
        for stats in job.agents:
            lines.append(
                table_row(
                    [
                        f"`{job.dataset}`",
                        f"`{stats.agent}`",
                        f"`{stats.model}`",
                        str(stats.n_trials),
                        str(stats.n_passed),
                        format_float(stats.pass_rate),
                        format_float(stats.mean_reward),
                        str(stats.exceptions),
                        str(stats.artifact_failures),
                        f"`{rel(job.path)}`",
                    ]
                )
            )

    lines.append("")
    for job in jobs:
        lines.extend(job_section(job))
    return lines


def report_filename(title: str, slug: str | None) -> str:
    date = datetime.now().strftime("%Y-%m-%d")
    base = slugify(slug or title)
    candidate = RUNS_DIR / f"{date}-{base}.md"
    if not candidate.exists():
        return candidate.name
    for index in range(2, 100):
        name = f"{date}-{base}-{index}.md"
        if not (RUNS_DIR / name).exists():
            return name
    raise SystemExit("could not choose a report filename")


def index_row(report_name: str, title: str, jobs: list[JobReport]) -> str:
    date = datetime.now().strftime("%Y-%m-%d")
    if len(jobs) == 1 and len(jobs[0].agents) == 1:
        job = jobs[0]
        stats = job.agents[0]
        notes = (
            f"{stats.n_trials} trials, {stats.exceptions} exceptions, "
            f"{stats.artifact_failures} artifact collection failures."
        )
        return table_row(
            [
                date,
                f"[{title}]({report_name})",
                f"`{stats.agent}`",
                f"`{stats.model}`",
                f"`{format_float(stats.pass_rate)}`",
                f"`{format_float(stats.mean_reward)}`",
                notes,
            ]
        )

    notes = ", ".join(
        f"{job.dataset}: "
        + "/".join(f"{stats.agent} {format_float(stats.pass_rate)}" for stats in job.agents)
        for job in jobs
    )
    return table_row(
        [
            date,
            f"[{title}]({report_name})",
            "`varies`",
            "`varies`",
            "`see report`",
            "`see report`",
            notes,
        ]
    )


def update_index(report_name: str, title: str, jobs: list[JobReport]) -> None:
    if not RUNS_INDEX.exists():
        return

    text = RUNS_INDEX.read_text(encoding="utf-8")
    row = index_row(report_name, title, jobs)
    if f"]({report_name})" in text:
        return

    marker = "| Date | Run | Agent | Model | Pass Rate | Mean Reward | Notes |\n"
    index = text.find(marker)
    if index == -1:
        return

    header_end = text.find("\n", index + len(marker))
    if header_end == -1:
        return
    insert_at = header_end + 1
    updated = text[:insert_at] + row + "\n" + text[insert_at:]
    RUNS_INDEX.write_text(updated, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", help="Harbor job output directories")
    parser.add_argument("--title", default="Harbor eval run")
    parser.add_argument("--slug")
    parser.add_argument(
        "--no-index",
        action="store_true",
        help="Write the report without updating evals/runs/RUNS.md.",
    )
    args = parser.parse_args()

    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    jobs = [read_job(Path(path)) for path in args.paths]
    report_name = report_filename(args.title, args.slug)
    report_path = RUNS_DIR / report_name
    report_path.write_text("\n".join(report_lines(args.title, jobs)) + "\n", encoding="utf-8")
    if not args.no_index:
        update_index(report_name, args.title, jobs)
    print(rel(report_path))


if __name__ == "__main__":
    main()
