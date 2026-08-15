from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Mapping, Sequence
from typing import TextIO

from scripts.pgso.model import PgsoError, require_empty_stderr as ensure_empty_stderr


COMMAND_HEARTBEAT_SECONDS = 30.0


@dataclasses.dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    elapsed_seconds: float


def emit_progress(message: str) -> None:
    print(f"[pgso] {message}", flush=True)


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


def _terminate_process_group(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def _stream_pipe(
    pipe: TextIO,
    sink: TextIO,
    chunks: list[str],
) -> None:
    try:
        while True:
            chunk = pipe.read(4096)
            if not chunk:
                return
            chunks.append(chunk)
            sink.write(chunk)
            sink.flush()
    finally:
        pipe.close()


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
    command_display = shlex.join(argv_tuple)
    emit_progress(f"command started: {command_display} (log: {log_path})")
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
        emit_progress(
            f"command spawn failed in {elapsed_seconds:.3f}s: "
            f"{command_display}: {error}"
        )
        if isinstance(error, FileNotFoundError):
            raise PgsoError(f"executable not found: {argv_tuple[0]}") from error
        raise PgsoError(f"could not start command: {error}") from error

    if process.stdout is None or process.stderr is None:
        _terminate_process_group(process)
        raise PgsoError("command output pipes were not created")

    stdout_chunks: list[str] = []
    stderr_chunks: list[str] = []
    stdout_thread = threading.Thread(
        target=_stream_pipe,
        args=(process.stdout, sys.stdout, stdout_chunks),
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=_stream_pipe,
        args=(process.stderr, sys.stderr, stderr_chunks),
        daemon=True,
    )
    stdout_thread.start()
    stderr_thread.start()

    timed_out = False
    deadline = time.monotonic() + timeout_s
    next_heartbeat = time.monotonic() + COMMAND_HEARTBEAT_SECONDS
    while process.poll() is None:
        now = time.monotonic()
        if now >= deadline:
            timed_out = True
            _terminate_process_group(process)
            break
        wait_seconds = max(0.001, min(deadline, next_heartbeat) - now)
        try:
            process.wait(timeout=wait_seconds)
        except subprocess.TimeoutExpired:
            now = time.monotonic()
            if now >= deadline:
                timed_out = True
                _terminate_process_group(process)
                break
            if now >= next_heartbeat:
                emit_progress(
                    f"command still running after {now - started:.1f}s: "
                    f"{command_display} (log: {log_path})"
                )
                while next_heartbeat <= now:
                    next_heartbeat += COMMAND_HEARTBEAT_SECONDS

    stdout_thread.join()
    stderr_thread.join()
    stdout = "".join(stdout_chunks)
    stderr = "".join(stderr_chunks)

    if timed_out:
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
        emit_progress(
            f"command timed out in {elapsed_seconds:.3f}s: {command_display}"
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
        emit_progress(
            f"command failed in {elapsed_seconds:.3f}s: {command_display} "
            f"(exit: {result.returncode})"
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
        emit_progress(
            f"command rejected stderr in {elapsed_seconds:.3f}s: {command_display}"
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
    emit_progress(f"command passed in {elapsed_seconds:.3f}s: {command_display}")
    return result
