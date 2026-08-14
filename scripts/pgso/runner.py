from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import signal
import subprocess
import time
from collections.abc import Mapping, Sequence

from scripts.pgso.model import PgsoError, require_empty_stderr as ensure_empty_stderr


@dataclasses.dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    elapsed_seconds: float


def _write_log(
    path: pathlib.Path,
    *,
    argv: tuple[str, ...],
    elapsed_seconds: float,
    returncode: int | None,
    stdout: str,
    stderr: str,
    status: str,
) -> None:
    payload = {
        "argv": argv,
        "command_class": pathlib.Path(argv[0]).name,
        "elapsed_seconds": elapsed_seconds,
        "returncode": returncode,
        "status": status,
        "stderr": stderr,
        "stdout": stdout,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _terminate_process_group(process: subprocess.Popen[str]) -> tuple[str, str]:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    try:
        return process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return process.communicate()


def run_checked(
    argv: Sequence[str | os.PathLike[str]],
    *,
    cwd: pathlib.Path,
    env: Mapping[str, str] | None,
    timeout_s: float,
    log_path: pathlib.Path,
    require_empty_stderr: bool = False,
) -> CommandResult:
    argv_tuple = tuple(os.fspath(argument) for argument in argv)
    if not argv_tuple:
        raise PgsoError("cannot run an empty command")
    if timeout_s <= 0:
        raise PgsoError("command timeout must be positive")

    started = time.monotonic()
    try:
        process = subprocess.Popen(
            argv_tuple,
            cwd=cwd,
            env=None if env is None else dict(env),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            start_new_session=True,
        )
    except OSError as error:
        elapsed_seconds = time.monotonic() - started
        _write_log(
            log_path,
            argv=argv_tuple,
            elapsed_seconds=elapsed_seconds,
            returncode=None,
            stdout="",
            stderr=str(error),
            status="spawn_failed",
        )
        if isinstance(error, FileNotFoundError):
            raise PgsoError(f"executable not found: {argv_tuple[0]}") from error
        raise PgsoError(f"could not start command: {error}") from error

    try:
        stdout, stderr = process.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        stdout, stderr = _terminate_process_group(process)
        elapsed_seconds = time.monotonic() - started
        _write_log(
            log_path,
            argv=argv_tuple,
            elapsed_seconds=elapsed_seconds,
            returncode=process.returncode,
            stdout=stdout,
            stderr=stderr,
            status="timed_out",
        )
        raise PgsoError(
            f"command timed out after {timeout_s:g} seconds: {argv_tuple[0]}"
        )

    elapsed_seconds = time.monotonic() - started
    result = CommandResult(
        argv=argv_tuple,
        returncode=process.returncode,
        stdout=stdout,
        stderr=stderr,
        elapsed_seconds=elapsed_seconds,
    )
    if result.returncode != 0:
        _write_log(
            log_path,
            argv=argv_tuple,
            elapsed_seconds=elapsed_seconds,
            returncode=result.returncode,
            stdout=stdout,
            stderr=stderr,
            status="failed",
        )
        raise PgsoError(
            f"command failed with exit code {result.returncode}: {argv_tuple[0]}"
        )

    if require_empty_stderr and stderr:
        _write_log(
            log_path,
            argv=argv_tuple,
            elapsed_seconds=elapsed_seconds,
            returncode=result.returncode,
            stdout=stdout,
            stderr=stderr,
            status="unexpected_stderr",
        )
        ensure_empty_stderr("command", stderr)

    _write_log(
        log_path,
        argv=argv_tuple,
        elapsed_seconds=elapsed_seconds,
        returncode=result.returncode,
        stdout=stdout,
        stderr=stderr,
        status="passed",
    )
    return result
