from __future__ import annotations

import dataclasses
import hashlib
import json
import pathlib


MIB = 1_048_576


class PgsoError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class BuildIdentity:
    source_sha: str
    target: str
    host_arch: str
    zig_version: str
    llvm_version: str
    bitcode_sha256: str
    corpus_sha256: str
    update_channel: str
    generation_flags: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class ArtifactEvidence:
    size_bytes: int
    size_mib: float
    ceiling_mib: float
    headroom_mib: float
    preferred_headroom_mib: float
    preferred_headroom_met: bool


@dataclasses.dataclass(frozen=True)
class RunManifest:
    identity: BuildIdentity
    status: str
    stage: str
    artifact: ArtifactEvidence | None = None
    warnings: tuple[str, ...] = ()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_identity(expected: BuildIdentity, actual: BuildIdentity) -> None:
    for field in dataclasses.fields(BuildIdentity):
        expected_value = getattr(expected, field.name)
        actual_value = getattr(actual, field.name)
        if expected_value != actual_value:
            raise PgsoError(
                f"identity mismatch: {field.name}: "
                f"expected {expected_value!r}, got {actual_value!r}"
            )


def bytes_to_mib(byte_count: int) -> float:
    return byte_count / MIB


def size_gate(
    byte_count: int,
    ceiling_mib: float = 7.800,
    preferred_headroom_mib: float = 0.250,
) -> ArtifactEvidence:
    if byte_count <= 0:
        raise PgsoError("artifact is empty or has an invalid negative size")

    size_mib = bytes_to_mib(byte_count)
    if size_mib > ceiling_mib:
        raise PgsoError(
            f"artifact size {size_mib:.6f} MiB exceeds "
            f"{ceiling_mib:.3f} MiB ceiling"
        )

    headroom_mib = ceiling_mib - size_mib
    return ArtifactEvidence(
        size_bytes=byte_count,
        size_mib=size_mib,
        ceiling_mib=ceiling_mib,
        headroom_mib=headroom_mib,
        preferred_headroom_mib=preferred_headroom_mib,
        preferred_headroom_met=headroom_mib >= preferred_headroom_mib,
    )


def require_empty_stderr(stage: str, stderr: str) -> None:
    if stderr:
        raise PgsoError(f"{stage} wrote unexpected stderr: {stderr}")


def write_manifest(path: pathlib.Path, manifest: RunManifest) -> None:
    payload = json.dumps(
        dataclasses.asdict(manifest),
        indent=2,
        sort_keys=True,
    )
    path.write_text(payload + "\n", encoding="utf-8")
