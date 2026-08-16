#!/usr/bin/env python3
"""Idempotent release publication domain logic.

The network-facing adapter lives in ``publish.py``. This module intentionally
keeps reconciliation deterministic so failure-boundary tests exercise the same
state machine used by GitHub Actions.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from enum import Enum
from typing import Mapping, Protocol


PLATFORMS = (
    "linux-x86_64",
    "linux-aarch64",
    "macos-x86_64",
    "macos-aarch64",
)
ASSET_NAMES = tuple(
    name
    for platform in PLATFORMS
    for name in (f"fx-{platform}.tar.gz", f"fx-{platform}.tar.gz.sha256")
)
SEMVER_RE = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_RELEASE_EPOCH = 0xFFFF_FFFF


class ReconcileConflict(RuntimeError):
    """Remote or bundle state disagrees with the authenticated publication."""


class InjectedFailure(RuntimeError):
    """Deterministic test-only publication interruption."""


class Mode(Enum):
    NORMAL = "normal"
    REPAIR = "repair"
    POST_CLEANUP_BRIDGE = "post-cleanup-bridge"


@dataclass(frozen=True)
class ObjectIdentity:
    size: int
    sha256: str


@dataclass(frozen=True)
class BundleIndex:
    schema_version: int
    tag: str
    source_sha: str
    epoch: int
    source_version: str
    release_title: str
    release_body: str
    release_metadata_sha256: str
    objects: Mapping[str, ObjectIdentity]

    @classmethod
    def create(
        cls,
        *,
        tag: str,
        source_sha: str,
        epoch: int,
        release_title: str,
        release_body: str,
        objects: Mapping[str, bytes],
    ) -> "BundleIndex":
        metadata = canonical_json_bytes({"title": release_title, "body": release_body})
        identities = {
            name: ObjectIdentity(size=len(body), sha256=sha256(body))
            for name, body in sorted(objects.items())
        }
        return cls(
            schema_version=1,
            tag=tag,
            source_sha=source_sha,
            epoch=epoch,
            source_version=tag.removeprefix("v"),
            release_title=release_title,
            release_body=release_body,
            release_metadata_sha256=sha256(metadata),
            objects=identities,
        )

    def as_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "tag": self.tag,
            "source_sha": self.source_sha,
            "epoch": self.epoch,
            "source_version": self.source_version,
            "release": {
                "title": self.release_title,
                "body": self.release_body,
                "sha256": self.release_metadata_sha256,
            },
            "objects": {
                name: {"size": identity.size, "sha256": identity.sha256}
                for name, identity in sorted(self.objects.items())
            },
        }

    def encode(self) -> bytes:
        return canonical_json_bytes(self.as_dict()) + b"\n"

    def digest(self) -> str:
        return sha256(self.encode())

    @classmethod
    def decode(cls, raw: bytes) -> "BundleIndex":
        try:
            value = json.loads(raw)
            release = value["release"]
            object_values = value["objects"]
            index = cls(
                schema_version=value["schema_version"],
                tag=value["tag"],
                source_sha=value["source_sha"],
                epoch=value["epoch"],
                source_version=value["source_version"],
                release_title=release["title"],
                release_body=release["body"],
                release_metadata_sha256=release["sha256"],
                objects={
                    name: ObjectIdentity(size=identity["size"], sha256=identity["sha256"])
                    for name, identity in object_values.items()
                },
            )
        except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError, AttributeError) as exc:
            raise ReconcileConflict("private bundle index is malformed") from exc
        if not all(
            isinstance(value, str)
            for value in (
                index.tag,
                index.source_sha,
                index.source_version,
                index.release_title,
                index.release_body,
                index.release_metadata_sha256,
            )
        ):
            raise ReconcileConflict("private bundle index has invalid field types")
        validate_identity(index)
        if raw != index.encode():
            raise ReconcileConflict("private bundle index is not canonical")
        return index


@dataclass
class Bundle:
    index: BundleIndex
    objects: Mapping[str, bytes]

    def validate(self) -> None:
        validate_identity(self.index)
        if set(self.objects) != set(ASSET_NAMES):
            raise ReconcileConflict("bundle must contain the exact eight release assets")
        if set(self.index.objects) != set(ASSET_NAMES):
            raise ReconcileConflict("bundle index must name the exact eight release assets")

        for name in ASSET_NAMES:
            body = self.objects[name]
            if not isinstance(body, bytes):
                raise ReconcileConflict(f"bundle object is not bytes: {name}")
            identity = self.index.objects[name]
            if len(body) != identity.size or sha256(body) != identity.sha256:
                raise ReconcileConflict(f"bundle object identity mismatch: {name}")

        for platform in PLATFORMS:
            archive_name = f"fx-{platform}.tar.gz"
            checksum_name = f"{archive_name}.sha256"
            try:
                fields = self.objects[checksum_name].decode("ascii", errors="strict").split()
            except UnicodeDecodeError as exc:
                raise ReconcileConflict(f"invalid checksum file: {checksum_name}") from exc
            if len(fields) != 2 or fields[1].lstrip("*") != archive_name:
                raise ReconcileConflict(f"invalid checksum file: {checksum_name}")
            if fields[0] != sha256(self.objects[archive_name]):
                raise ReconcileConflict(f"checksum does not authenticate archive: {archive_name}")


@dataclass
class Release:
    tag: str
    title: str
    body: str
    assets: Mapping[str, bytes]


class Backend(Protocol):
    def read_tag(self, tag: str) -> str | None: ...

    def create_tag(self, tag: str, source_sha: str) -> None: ...

    def read_release(self, tag: str) -> Release | None: ...

    def create_release(self, tag: str, title: str, body: str) -> None: ...

    def upload_release_asset(self, tag: str, name: str, body: bytes) -> None: ...

    def read_cdn(self, path: str) -> bytes | None: ...

    def write_cdn(self, path: str, body: bytes, *, mutable: bool) -> None: ...


def reconcile(
    backend: Backend,
    bundle: Bundle,
    *,
    mode: Mode,
    bridge_tag: str,
    pinned_index_digest: str | None = None,
    fault_after: str | None = None,
) -> None:
    """Converge publication state or fail before mixing identities."""

    bundle.validate()
    index = bundle.index
    if not SEMVER_RE.fullmatch(bridge_tag):
        raise ReconcileConflict("bridge tag is not strict SemVer")

    if mode is Mode.POST_CLEANUP_BRIDGE:
        if index.tag != bridge_tag or index.epoch != 0:
            raise ReconcileConflict("post-cleanup mode is pinned to the epoch-zero bridge")
        if pinned_index_digest is None or pinned_index_digest != index.digest():
            raise ReconcileConflict("post-cleanup bridge index digest is not pinned")
        _preflight_cdn(backend, bundle)
        _reconcile_cdn(backend, bundle, fault_after)
        _reconcile_latest_pointer(backend, index.tag, fault_after)
        return

    tag_sha = backend.read_tag(index.tag)
    if tag_sha is not None and tag_sha != index.source_sha:
        raise ReconcileConflict("tag resolves to a different source SHA")
    if mode is Mode.REPAIR and tag_sha is None:
        raise ReconcileConflict("guarded repair requires an existing exact-SHA tag")

    release = backend.read_release(index.tag)
    _preflight_release(bundle, release)
    _preflight_cdn(backend, bundle)
    stable_action = _stable_pointer_action(backend.read_cdn("cli/stable.json"), index)
    latest_action = "preserve"
    if index.epoch == 0:
        if index.tag != bridge_tag:
            raise ReconcileConflict("only the configured bridge may publish epoch-zero pointers")
        latest_action = _latest_pointer_action(backend.read_cdn("cli/latest.txt"), index.tag)

    if tag_sha is None:
        backend.create_tag(index.tag, index.source_sha)
        _fault(fault_after, "after_tag")
        if backend.read_tag(index.tag) != index.source_sha:
            raise ReconcileConflict("tag read-back did not match the source SHA")

    if release is None:
        backend.create_release(index.tag, index.release_title, index.release_body)
        _fault(fault_after, "after_release")
        release = backend.read_release(index.tag)
        _preflight_release(bundle, release)

    present_assets = set(release.assets)
    uploaded = 0
    for name in ASSET_NAMES:
        if name in present_assets:
            continue
        backend.upload_release_asset(index.tag, name, bundle.objects[name])
        uploaded += 1
        read_back = backend.read_release(index.tag)
        if read_back is None or read_back.assets.get(name) != bundle.objects[name]:
            raise ReconcileConflict(f"release asset read-back mismatch: {name}")
        _fault(fault_after, f"after_release_asset_{len(present_assets) + uploaded}")

    complete_release = backend.read_release(index.tag)
    _preflight_release(bundle, complete_release, require_complete=True)

    _reconcile_cdn(backend, bundle, fault_after)

    if latest_action == "write":
        _fault(fault_after, "before_latest_pointer")
        backend.write_cdn("cli/latest.txt", f"{index.tag}\n".encode(), mutable=True)
        if backend.read_cdn("cli/latest.txt") != f"{index.tag}\n".encode():
            raise ReconcileConflict("latest pointer read-back mismatch")
        _fault(fault_after, "after_latest_pointer")

    if stable_action == "write":
        _fault(fault_after, "before_stable_pointer")
        stable = stable_manifest(index)
        backend.write_cdn("cli/stable.json", stable, mutable=True)
        if backend.read_cdn("cli/stable.json") != stable:
            raise ReconcileConflict("stable pointer read-back mismatch")


def _preflight_release(bundle: Bundle, release: Release | None, *, require_complete: bool = False) -> None:
    if release is None:
        if require_complete:
            raise ReconcileConflict("release is absent after reconciliation")
        return
    index = bundle.index
    if release.tag != index.tag or release.title != index.release_title or release.body != index.release_body:
        raise ReconcileConflict("release identity or metadata mismatch")
    names = set(release.assets)
    unexpected = names - set(ASSET_NAMES)
    if unexpected:
        raise ReconcileConflict(f"release contains unexpected assets: {sorted(unexpected)}")
    for name, body in release.assets.items():
        if body != bundle.objects[name]:
            raise ReconcileConflict(f"release asset digest mismatch: {name}")
    if require_complete and names != set(ASSET_NAMES):
        raise ReconcileConflict("release asset set is incomplete")


def _preflight_cdn(backend: Backend, bundle: Bundle) -> None:
    for name, expected in bundle.objects.items():
        path = f"cli/{bundle.index.tag}/{name}"
        actual = backend.read_cdn(path)
        if actual is not None and actual != expected:
            raise ReconcileConflict(f"CDN object digest mismatch: {path}")


def _reconcile_cdn(backend: Backend, bundle: Bundle, fault_after: str | None) -> None:
    completed = 0
    for name in ASSET_NAMES:
        path = f"cli/{bundle.index.tag}/{name}"
        expected = bundle.objects[name]
        if backend.read_cdn(path) is None:
            backend.write_cdn(path, expected, mutable=False)
        if backend.read_cdn(path) != expected:
            raise ReconcileConflict(f"CDN object read-back mismatch: {path}")
        completed += 1
        _fault(fault_after, f"after_cdn_asset_{completed}")


def _reconcile_latest_pointer(backend: Backend, tag: str, fault_after: str | None) -> None:
    if _latest_pointer_action(backend.read_cdn("cli/latest.txt"), tag) == "preserve":
        return
    _fault(fault_after, "before_latest_pointer")
    expected = f"{tag}\n".encode()
    backend.write_cdn("cli/latest.txt", expected, mutable=True)
    if backend.read_cdn("cli/latest.txt") != expected:
        raise ReconcileConflict("latest pointer read-back mismatch")
    _fault(fault_after, "after_latest_pointer")


def _stable_pointer_action(raw: bytes | None, target: BundleIndex) -> str:
    if raw is None:
        return "write"
    current = parse_stable_manifest(raw)
    target_identity = (target.epoch, semver_parts(target.tag))
    current_identity = (current[0], semver_parts(current[1]))
    if current_identity > target_identity:
        return "preserve"
    if current_identity == target_identity:
        if current[1] != target.tag:
            raise ReconcileConflict("stable pointer has a non-canonical equal identity")
        return "preserve"
    return "write"


def _latest_pointer_action(raw: bytes | None, target_tag: str) -> str:
    if raw is None:
        return "write"
    try:
        current = raw.decode("ascii").strip()
    except UnicodeDecodeError as exc:
        raise ReconcileConflict("latest pointer is not ASCII") from exc
    if not SEMVER_RE.fullmatch(current):
        raise ReconcileConflict("latest pointer is not strict SemVer")
    current_parts = semver_parts(current)
    target_parts = semver_parts(target_tag)
    if current_parts > target_parts:
        raise ReconcileConflict("latest pointer would move backward")
    return "preserve" if current_parts == target_parts else "write"


def parse_stable_manifest(raw: bytes) -> tuple[int, str]:
    if len(raw) > 4096:
        raise ReconcileConflict("stable pointer is oversized")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReconcileConflict("stable pointer is malformed") from exc
    if not isinstance(value, dict):
        raise ReconcileConflict("stable pointer must be an object")
    epoch = value.get("epoch")
    version = value.get("version")
    if (
        isinstance(epoch, bool)
        or not isinstance(epoch, int)
        or epoch < 0
        or epoch > MAX_RELEASE_EPOCH
    ):
        raise ReconcileConflict("stable pointer epoch is invalid")
    if not isinstance(version, str) or not SEMVER_RE.fullmatch(version):
        raise ReconcileConflict("stable pointer version is invalid")
    return epoch, version


def stable_manifest(index: BundleIndex) -> bytes:
    return canonical_json_bytes({"epoch": index.epoch, "version": index.tag}) + b"\n"


def validate_identity(index: BundleIndex) -> None:
    if isinstance(index.schema_version, bool) or not isinstance(index.schema_version, int):
        raise ReconcileConflict("bundle index schema has an invalid type")
    if index.schema_version != 1:
        raise ReconcileConflict("unsupported bundle index schema")
    if not SEMVER_RE.fullmatch(index.tag):
        raise ReconcileConflict("bundle tag is not strict SemVer")
    if not SHA_RE.fullmatch(index.source_sha):
        raise ReconcileConflict("bundle source SHA is invalid")
    if (
        isinstance(index.epoch, bool)
        or not isinstance(index.epoch, int)
        or index.epoch < 0
        or index.epoch > MAX_RELEASE_EPOCH
    ):
        raise ReconcileConflict("bundle epoch is invalid")
    if index.source_version != index.tag.removeprefix("v"):
        raise ReconcileConflict("bundle source version does not match its tag")
    metadata = canonical_json_bytes({"title": index.release_title, "body": index.release_body})
    if index.release_metadata_sha256 != sha256(metadata):
        raise ReconcileConflict("release metadata digest mismatch")
    for name, identity in index.objects.items():
        if not isinstance(name, str):
            raise ReconcileConflict("invalid object identity name")
        if (
            isinstance(identity.size, bool)
            or not isinstance(identity.size, int)
            or identity.size < 0
            or not isinstance(identity.sha256, str)
            or not SHA256_RE.fullmatch(identity.sha256)
        ):
            raise ReconcileConflict("invalid object identity")


def semver_parts(tag: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(tag)
    if match is None:
        raise ReconcileConflict("version is not strict SemVer")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def canonical_json_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def _fault(configured: str | None, boundary: str) -> None:
    if configured == boundary:
        raise InjectedFailure(boundary)
