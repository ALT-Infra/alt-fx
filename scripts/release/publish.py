#!/usr/bin/env python3
"""Seal private bundles and reconcile GitHub/CDN release publication."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Protocol

from scripts.release.reconcile import (
    ASSET_NAMES,
    Bundle,
    BundleIndex,
    Mode,
    ReconcileConflict,
    Release,
    SEMVER_RE,
    SHA256_RE,
    reconcile,
    sha256,
)


DEFAULT_PUBLIC_CDN_ORIGIN = "https://ugiwefobuo4tac0m.public.blob.vercel-storage.com"


class BundleReader(Protocol):
    def read(self, path: str) -> bytes | None: ...


class BundleStore(BundleReader, Protocol):
    def write_immutable(self, path: str, body: bytes) -> None: ...


def seal_bundle(store: BundleStore, bundle: Bundle, *, prefix: str) -> str:
    """Seal and read-verify a bundle, publishing its index only after all bytes."""

    bundle.validate()
    index_path = _bundle_index_path(prefix, bundle.index.tag)
    expected_index = bundle.index.encode()

    existing_index = store.read(index_path)
    if existing_index is not None and existing_index != expected_index:
        raise ReconcileConflict("private bundle index conflicts with the intended release")

    # Preflight every existing object before filling any missing state.
    for name in ASSET_NAMES:
        identity = bundle.index.objects[name]
        existing = store.read(_bundle_object_path(prefix, identity.sha256))
        if existing is not None and existing != bundle.objects[name]:
            raise ReconcileConflict(f"private bundle object conflicts: {name}")

    for name in ASSET_NAMES:
        identity = bundle.index.objects[name]
        path = _bundle_object_path(prefix, identity.sha256)
        expected = bundle.objects[name]
        if store.read(path) is None:
            store.write_immutable(path, expected)
        if store.read(path) != expected:
            raise ReconcileConflict(f"private bundle read-back mismatch: {name}")

    if existing_index is None:
        store.write_immutable(index_path, expected_index)
    if store.read(index_path) != expected_index:
        raise ReconcileConflict("private bundle index read-back mismatch")
    return bundle.index.digest()


def load_bundle(
    store: BundleReader,
    tag: str,
    *,
    prefix: str,
    pinned_index_digest: str | None = None,
) -> Bundle:
    raw_index = store.read(_bundle_index_path(prefix, tag))
    if raw_index is None:
        raise ReconcileConflict(f"private bundle is absent: {tag}")
    index = BundleIndex.decode(raw_index)
    if index.tag != tag:
        raise ReconcileConflict("private bundle tag does not match its fixed path")
    if pinned_index_digest is not None and sha256(raw_index) != pinned_index_digest:
        raise ReconcileConflict("private bundle index digest does not match the pin")

    objects: dict[str, bytes] = {}
    for name in ASSET_NAMES:
        body = store.read(_bundle_object_path(prefix, index.objects[name].sha256))
        if body is None:
            raise ReconcileConflict(f"private bundle object is absent: {name}")
        objects[name] = body
    bundle = Bundle(index=index, objects=objects)
    bundle.validate()
    return bundle


def _bundle_root(prefix: str, tag: str) -> str:
    normalized = prefix.strip("/")
    if not normalized or "/../" in f"/{normalized}/" or not SEMVER_RE.fullmatch(tag):
        raise ReconcileConflict("private bundle prefix is invalid")
    return f"{normalized}/releases/{tag}"


def _bundle_index_path(prefix: str, tag: str) -> str:
    return f"{_bundle_root(prefix, tag)}/index.json"


def _bundle_object_path(prefix: str, digest: str) -> str:
    normalized = prefix.strip("/")
    if not normalized or "/../" in f"/{normalized}/" or not SHA256_RE.fullmatch(digest):
        raise ReconcileConflict("private bundle object path is invalid")
    return f"{normalized}/objects/{digest}"


class HttpBundleReader:
    """Authenticated fixed-path reader for a least-privilege bundle endpoint."""

    def __init__(self, *, read_origin: str, token: str) -> None:
        origin, _ = _validated_https_origin(read_origin)
        if not token:
            raise ReconcileConflict("private bundle read token is missing")
        self.read_origin = origin
        self.token = token

    def read(self, path: str) -> bytes | None:
        return _http_read(f"{self.read_origin}/{_quote_path(path)}", token=self.token)


class BlobBundleStore(HttpBundleReader):
    """Fixed-path private Vercel Blob writer used only while sealing."""

    def __init__(self, *, read_origin: str, token: str) -> None:
        origin, hostname = _validated_https_origin(read_origin)
        if not hostname.endswith(".private.blob.vercel-storage.com"):
            raise ReconcileConflict("private bundle origin must be a private Vercel Blob origin")
        super().__init__(read_origin=origin, token=token)

    def write_immutable(self, path: str, body: bytes) -> None:
        _blob_put(path, body, token=self.token, mutable=False)


class GitHubCdnBackend:
    def __init__(
        self,
        *,
        repository: str,
        public_cdn_origin: str,
        public_blob_token: str,
    ) -> None:
        if not repository or "/" not in repository:
            raise ReconcileConflict("GitHub repository must be owner/name")
        if not public_blob_token:
            raise ReconcileConflict("public Blob token is missing")
        self.repository = repository
        self.public_cdn_origin = public_cdn_origin.rstrip("/")
        self.public_blob_token = public_blob_token

    def read_tag(self, tag: str) -> str | None:
        result = _run(
            ["git", "ls-remote", "--refs", "origin", f"refs/tags/{tag}"],
            check=True,
        ).stdout.decode().strip()
        if not result:
            return None
        fields = result.split()
        if len(fields) != 2 or fields[1] != f"refs/tags/{tag}":
            raise ReconcileConflict("unexpected remote tag response")
        return fields[0]

    def create_tag(self, tag: str, source_sha: str) -> None:
        _run(["git", "tag", "--", tag, source_sha], check=True)
        _run(["git", "push", "origin", f"refs/tags/{tag}"], check=True)

    def read_release(self, tag: str) -> Release | None:
        response = _gh_api_json(
            [f"repos/{self.repository}/releases/tags/{tag}"],
            allow_not_found=True,
        )
        if response is None:
            return None
        assets: dict[str, bytes] = {}
        for asset in response.get("assets", []):
            name = asset.get("name")
            asset_id = asset.get("id")
            if not isinstance(name, str) or not isinstance(asset_id, int):
                raise ReconcileConflict("GitHub Release returned invalid asset metadata")
            if name in assets:
                raise ReconcileConflict(f"GitHub Release contains duplicate asset: {name}")
            assets[name] = _run(
                [
                    "gh",
                    "api",
                    "-H",
                    "Accept: application/octet-stream",
                    f"repos/{self.repository}/releases/assets/{asset_id}",
                ],
                check=True,
            ).stdout
        title = response.get("name")
        body = response.get("body")
        return Release(
            tag=response.get("tag_name"),
            title=title if isinstance(title, str) else "",
            body=body if isinstance(body, str) else "",
            assets=assets,
        )

    def create_release(self, tag: str, title: str, body: str) -> None:
        _run(
            [
                "gh",
                "release",
                "create",
                tag,
                "--repo",
                self.repository,
                "--verify-tag",
                "--title",
                title,
                "--notes-file",
                "-",
            ],
            check=True,
            input_bytes=body.encode(),
        )

    def upload_release_asset(self, tag: str, name: str, body: bytes) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-release-asset-") as temp_dir:
            asset_path = Path(temp_dir, name)
            asset_path.write_bytes(body)
            _run(
                [
                    "gh",
                    "release",
                    "upload",
                    tag,
                    str(asset_path),
                    "--repo",
                    self.repository,
                ],
                check=True,
            )

    def read_cdn(self, path: str) -> bytes | None:
        nonce = uuid.uuid4().hex
        url = f"{self.public_cdn_origin}/{_quote_path(path)}?verify={nonce}"
        return _http_read(url)

    def write_cdn(self, path: str, body: bytes, *, mutable: bool) -> None:
        _blob_put(path, body, token=self.public_blob_token, mutable=mutable)


def build_local_bundle(
    *,
    asset_dir: Path,
    tag: str,
    source_sha: str,
    epoch: int,
    release_title: str,
    release_body: str,
) -> Bundle:
    actual_names = {path.name for path in asset_dir.iterdir() if path.is_file()}
    if actual_names != set(ASSET_NAMES):
        missing = sorted(set(ASSET_NAMES) - actual_names)
        unexpected = sorted(actual_names - set(ASSET_NAMES))
        raise ReconcileConflict(f"release asset directory mismatch; missing={missing}, unexpected={unexpected}")
    objects = {name: Path(asset_dir, name).read_bytes() for name in ASSET_NAMES}
    index = BundleIndex.create(
        tag=tag,
        source_sha=source_sha,
        epoch=epoch,
        release_title=release_title,
        release_body=release_body,
        objects=objects,
    )
    bundle = Bundle(index=index, objects=objects)
    bundle.validate()
    return bundle


def extract_release_notes(changelog: Path) -> str:
    start = "<!-- release:start -->"
    end = "<!-- release:end -->"
    lines = changelog.read_text().splitlines(keepends=True)
    try:
        start_index = next(index for index, line in enumerate(lines) if start in line) + 1
        end_index = next(index for index, line in enumerate(lines[start_index:], start_index) if end in line)
    except StopIteration as exc:
        raise ReconcileConflict("release-note markers are missing") from exc
    body = "".join(lines[start_index:end_index])
    if len([line for line in body.splitlines() if line.strip()]) < 2:
        raise ReconcileConflict("release notes must contain at least two non-empty lines")
    return body


def _assert_expected_identity(bundle: Bundle, *, tag: str, source_sha: str, epoch: int) -> None:
    index = bundle.index
    if (index.tag, index.source_sha, index.epoch) != (tag, source_sha, epoch):
        raise ReconcileConflict("private bundle identity does not match the requested publication")


def _load_config(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ReconcileConflict("release configuration is unreadable") from exc
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise ReconcileConflict("release configuration schema is invalid")
    return value


def _private_reader_from_env() -> HttpBundleReader:
    return HttpBundleReader(
        read_origin=os.environ.get("RELEASE_BUNDLE_READ_ORIGIN", ""),
        token=os.environ.get("RELEASE_BUNDLE_READ_TOKEN", ""),
    )


def _private_writer_from_env() -> BlobBundleStore:
    return BlobBundleStore(
        read_origin=os.environ.get("RELEASE_BUNDLE_PRIVATE_ORIGIN", ""),
        token=os.environ.get("RELEASE_BUNDLE_WRITE_TOKEN", ""),
    )


def _config_string(config: dict[str, object], key: str) -> str:
    value = config.get(key)
    if not isinstance(value, str) or not value:
        raise ReconcileConflict(f"release configuration field is invalid: {key}")
    return value


def _cmd_bundle_status(args: argparse.Namespace, config: dict[str, object]) -> int:
    if args.tag == _config_string(config, "legacy_terminal_tag"):
        print("legacy-complete")
        return 0
    store = _private_reader_from_env()
    prefix = _config_string(config, "private_bundle_prefix")
    raw_index = store.read(_bundle_index_path(prefix, args.tag))
    if raw_index is None:
        if args.tag_exists:
            raise ReconcileConflict("tag exists without its authenticated private bundle")
        print("build")
        return 0
    bundle = load_bundle(store, args.tag, prefix=prefix)
    _assert_expected_identity(bundle, tag=args.tag, source_sha=args.source_sha, epoch=args.epoch)
    print("resume")
    return 0


def _cmd_bundle_identity(args: argparse.Namespace, config: dict[str, object]) -> int:
    bundle = load_bundle(
        _private_reader_from_env(),
        args.tag,
        prefix=_config_string(config, "private_bundle_prefix"),
    )
    print(json.dumps({
        "tag": bundle.index.tag,
        "source_sha": bundle.index.source_sha,
        "epoch": bundle.index.epoch,
        "index_sha256": bundle.index.digest(),
    }, sort_keys=True, separators=(",", ":")))
    return 0


def _cmd_seal(args: argparse.Namespace, config: dict[str, object]) -> int:
    body = extract_release_notes(Path(args.changelog))
    bundle = build_local_bundle(
        asset_dir=Path(args.asset_dir),
        tag=args.tag,
        source_sha=args.source_sha,
        epoch=args.epoch,
        release_title=f"fx {args.tag}",
        release_body=body,
    )
    digest = seal_bundle(
        _private_writer_from_env(),
        bundle,
        prefix=_config_string(config, "private_bundle_prefix"),
    )
    print(digest)
    return 0


def _cmd_reconcile(args: argparse.Namespace, config: dict[str, object]) -> int:
    prefix = _config_string(config, "private_bundle_prefix")
    bridge_tag = _config_string(config, "bridge_tag")
    store = _private_reader_from_env()
    pinned_digest = None
    if args.mode == Mode.POST_CLEANUP_BRIDGE.value:
        post_cleanup = config.get("post_cleanup_bridge")
        if not isinstance(post_cleanup, dict) or post_cleanup.get("enabled") is not True:
            raise ReconcileConflict("post-cleanup bridge repair is not enabled and pinned")
        tag = post_cleanup.get("tag")
        source_sha = post_cleanup.get("source_sha")
        pinned_digest = post_cleanup.get("index_sha256")
        if not all(isinstance(value, str) and value for value in (tag, source_sha, pinned_digest)):
            raise ReconcileConflict("post-cleanup bridge repair identity is incomplete")
        epoch = 0
    else:
        tag = args.tag
        source_sha = args.source_sha
        epoch = args.epoch
    bundle = load_bundle(store, tag, prefix=prefix, pinned_index_digest=pinned_digest)
    _assert_expected_identity(bundle, tag=tag, source_sha=source_sha, epoch=epoch)
    backend = GitHubCdnBackend(
        repository=os.environ.get("GITHUB_REPOSITORY", ""),
        public_cdn_origin=os.environ.get("FX_PUBLIC_CDN_ORIGIN", DEFAULT_PUBLIC_CDN_ORIGIN),
        public_blob_token=os.environ.get("BLOB_READ_WRITE_TOKEN", ""),
    )
    reconcile(
        backend,
        bundle,
        mode=Mode(args.mode),
        bridge_tag=bridge_tag,
        pinned_index_digest=pinned_digest,
    )
    print(f"reconciled {tag} ({args.mode})")
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=".github/release-config.json")
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("bundle-status")
    status.add_argument("--tag", required=True)
    status.add_argument("--source-sha", required=True)
    status.add_argument("--epoch", required=True, type=int)
    status.add_argument("--tag-exists", action="store_true")

    identity = subparsers.add_parser("bundle-identity")
    identity.add_argument("--tag", required=True)

    seal = subparsers.add_parser("seal")
    seal.add_argument("--asset-dir", required=True)
    seal.add_argument("--changelog", default="CHANGELOG.md")
    seal.add_argument("--tag", required=True)
    seal.add_argument("--source-sha", required=True)
    seal.add_argument("--epoch", required=True, type=int)

    publish = subparsers.add_parser("reconcile")
    publish.add_argument("--mode", required=True, choices=[mode.value for mode in Mode])
    publish.add_argument("--tag")
    publish.add_argument("--source-sha")
    publish.add_argument("--epoch", type=int)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        config = _load_config(Path(args.config))
        if args.command == "bundle-status":
            return _cmd_bundle_status(args, config)
        if args.command == "bundle-identity":
            return _cmd_bundle_identity(args, config)
        if args.command == "seal":
            return _cmd_seal(args, config)
        if args.command == "reconcile":
            if args.mode != Mode.POST_CLEANUP_BRIDGE.value and (
                not args.tag or not args.source_sha or args.epoch is None
            ):
                raise ReconcileConflict("normal and repair modes require tag, source SHA, and epoch")
            return _cmd_reconcile(args, config)
        raise ReconcileConflict("unknown release command")
    except ReconcileConflict as exc:
        print(f"release publication blocked: {exc}", file=sys.stderr)
        return 1


def _gh_api_json(arguments: list[str], *, allow_not_found: bool) -> dict[str, object] | None:
    result = _run(["gh", "api", *arguments], check=False)
    if result.returncode != 0:
        if allow_not_found and b"HTTP 404" in result.stderr:
            return None
        raise ReconcileConflict(result.stderr.decode(errors="replace").strip() or "GitHub API request failed")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ReconcileConflict("GitHub API returned invalid JSON") from exc
    if not isinstance(value, dict):
        raise ReconcileConflict("GitHub API returned an unexpected payload")
    return value


def _run(
    command: list[str],
    *,
    check: bool,
    input_bytes: bytes | None = None,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(command, input=input_bytes, capture_output=True, check=False)
    if check and result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise ReconcileConflict(detail or f"command failed: {command[0]}")
    return result


def _http_read(url: str, *, token: str | None = None) -> bytes | None:
    headers = {"cache-control": "no-cache"}
    if token is not None:
        headers["authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            if response.status != 200:
                raise ReconcileConflict(f"object read failed with HTTP {response.status}")
            return response.read()
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise ReconcileConflict(f"object read failed with HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise ReconcileConflict("object read failed") from exc


def _validated_https_origin(raw: str) -> tuple[str, str]:
    if not raw or raw != raw.strip():
        raise ReconcileConflict("private bundle origin must be an exact HTTPS origin")
    try:
        parsed = urllib.parse.urlsplit(raw)
        port = parsed.port
    except ValueError as exc:
        raise ReconcileConflict("private bundle origin must be an exact HTTPS origin") from exc
    hostname = parsed.hostname
    if (
        parsed.scheme != "https"
        or hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise ReconcileConflict("private bundle origin must be an exact HTTPS origin")
    return f"https://{hostname}", hostname


def _blob_put(path: str, body: bytes, *, token: str, mutable: bool) -> None:
    content_type = "application/octet-stream"
    if path.endswith(".json"):
        content_type = "application/json"
    elif path.endswith(".sha256") or path.endswith(".txt"):
        content_type = "text/plain"
    elif path.endswith(".tar.gz"):
        content_type = "application/gzip"
    headers = {
        "authorization": f"Bearer {token}",
        "x-api-version": "7",
        "x-content-type": content_type,
        "x-add-random-suffix": "0",
        "x-allow-overwrite": "1" if mutable else "0",
        "x-cache-control-max-age": "60" if mutable else "31536000",
    }
    request = urllib.request.Request(
        f"https://blob.vercel-storage.com/{_quote_path(path)}",
        data=body,
        headers=headers,
        method="PUT",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            if response.status < 200 or response.status >= 300:
                raise ReconcileConflict(f"Blob upload failed with HTTP {response.status}")
    except urllib.error.HTTPError as exc:
        # A concurrent immutable writer is safe only if the caller's read-back
        # proves the exact intended bytes.
        if not mutable and exc.code in (409, 412):
            return
        raise ReconcileConflict(f"Blob upload failed with HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise ReconcileConflict("Blob upload failed") from exc


def _quote_path(path: str) -> str:
    return urllib.parse.quote(path.strip("/"), safe="/-._")


if __name__ == "__main__":
    raise SystemExit(main())
