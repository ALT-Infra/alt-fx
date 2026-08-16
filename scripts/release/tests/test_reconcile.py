from __future__ import annotations

import copy
import hashlib
import json
import unittest

from scripts.release.reconcile import (
    ASSET_NAMES,
    Bundle,
    BundleIndex,
    InjectedFailure,
    Mode,
    ReconcileConflict,
    Release,
    reconcile,
)
from scripts.release.publish import load_bundle, seal_bundle


def make_bundle(tag: str = "v0.4.5", epoch: int = 0) -> Bundle:
    objects: dict[str, bytes] = {}
    for name in ASSET_NAMES:
        if name.endswith(".sha256"):
            continue
        archive = f"archive bytes for {name}".encode()
        objects[name] = archive
        digest = hashlib.sha256(archive).hexdigest()
        objects[f"{name}.sha256"] = f"{digest}  {name}\n".encode()
    index = BundleIndex.create(
        tag=tag,
        source_sha="a" * 40,
        epoch=epoch,
        release_title=f"fx {tag}",
        release_body="release notes\n",
        objects=objects,
    )
    return Bundle(index=index, objects=objects)


class FakeBackend:
    def __init__(self) -> None:
        self.tags: dict[str, str] = {}
        self.releases: dict[str, Release] = {}
        self.cdn: dict[str, bytes] = {}
        self.writes: list[str] = []

    def clone(self) -> "FakeBackend":
        return copy.deepcopy(self)

    def read_tag(self, tag: str) -> str | None:
        return self.tags.get(tag)

    def create_tag(self, tag: str, source_sha: str) -> None:
        self.writes.append(f"tag:{tag}")
        self.tags[tag] = source_sha

    def read_release(self, tag: str) -> Release | None:
        return copy.deepcopy(self.releases.get(tag))

    def create_release(self, tag: str, title: str, body: str) -> None:
        self.writes.append(f"release:{tag}")
        self.releases[tag] = Release(tag=tag, title=title, body=body, assets={})

    def upload_release_asset(self, tag: str, name: str, body: bytes) -> None:
        self.writes.append(f"release-asset:{name}")
        self.releases[tag].assets[name] = body

    def read_cdn(self, path: str) -> bytes | None:
        return self.cdn.get(path)

    def write_cdn(self, path: str, body: bytes, *, mutable: bool) -> None:
        self.writes.append(f"cdn:{path}")
        self.cdn[path] = body


class FakeBundleStore:
    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}
        self.writes: list[str] = []

    def read(self, path: str) -> bytes | None:
        return self.objects.get(path)

    def write_immutable(self, path: str, body: bytes) -> None:
        self.writes.append(path)
        if path in self.objects:
            raise AssertionError("immutable object overwrite")
        self.objects[path] = body


class ReconcileTests(unittest.TestCase):
    def assert_complete(self, backend: FakeBackend, bundle: Bundle) -> None:
        tag = bundle.index.tag
        self.assertEqual(bundle.index.source_sha, backend.tags[tag])
        release = backend.releases[tag]
        self.assertEqual(bundle.index.release_title, release.title)
        self.assertEqual(bundle.index.release_body, release.body)
        self.assertEqual(bundle.objects, release.assets)
        for name, body in bundle.objects.items():
            self.assertEqual(body, backend.cdn[f"cli/{tag}/{name}"])
        stable = f'{{"epoch":{bundle.index.epoch},"version":"{tag}"}}\n'.encode()
        self.assertEqual(stable, backend.cdn["cli/stable.json"])

    def test_epoch_zero_publication_writes_both_pointers_last(self) -> None:
        bundle = make_bundle()
        backend = FakeBackend()
        reconcile(backend, bundle, mode=Mode.NORMAL, bridge_tag=bundle.index.tag)

        self.assert_complete(backend, bundle)
        self.assertEqual(b"v0.4.5\n", backend.cdn["cli/latest.txt"])
        self.assertEqual("cdn:cli/latest.txt", backend.writes[-2])
        self.assertEqual("cdn:cli/stable.json", backend.writes[-1])

    def test_epoch_one_publication_preserves_the_legacy_pointer(self) -> None:
        bundle = make_bundle(tag="v0.0.1", epoch=1)
        backend = FakeBackend()
        backend.cdn["cli/latest.txt"] = b"v0.4.5\n"
        reconcile(backend, bundle, mode=Mode.NORMAL, bridge_tag="v0.4.5")

        self.assert_complete(backend, bundle)
        self.assertEqual(b"v0.4.5\n", backend.cdn["cli/latest.txt"])
        self.assertNotIn("cdn:cli/latest.txt", backend.writes)
        self.assertEqual("cdn:cli/stable.json", backend.writes[-1])

    def test_every_persisted_failure_boundary_resumes_without_moving_the_tag(self) -> None:
        bundle = make_bundle()
        boundaries = [
            "after_tag",
            "after_release",
            *[f"after_release_asset_{count}" for count in range(1, 8)],
            *[f"after_cdn_asset_{count}" for count in range(1, 9)],
            "before_latest_pointer",
            "after_latest_pointer",
            "before_stable_pointer",
        ]

        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                backend = FakeBackend()
                with self.assertRaises(InjectedFailure):
                    reconcile(
                        backend,
                        bundle,
                        mode=Mode.NORMAL,
                        bridge_tag=bundle.index.tag,
                        fault_after=boundary,
                    )
                tag_sha = backend.tags.get(bundle.index.tag)
                reconcile(
                    backend,
                    bundle,
                    mode=Mode.REPAIR,
                    bridge_tag=bundle.index.tag,
                )
                self.assert_complete(backend, bundle)
                self.assertEqual(tag_sha, backend.tags[bundle.index.tag])
                self.assertEqual(1, backend.writes.count(f"tag:{bundle.index.tag}"))

    def test_complete_publication_is_an_idempotent_no_op(self) -> None:
        bundle = make_bundle()
        backend = FakeBackend()
        reconcile(backend, bundle, mode=Mode.NORMAL, bridge_tag=bundle.index.tag)
        backend.writes.clear()

        reconcile(backend, bundle, mode=Mode.REPAIR, bridge_tag=bundle.index.tag)

        self.assertEqual([], backend.writes)

    def test_identity_conflicts_fail_before_any_write(self) -> None:
        bundle = make_bundle()
        cases: list[tuple[str, FakeBackend]] = []

        wrong_tag = FakeBackend()
        wrong_tag.tags[bundle.index.tag] = "b" * 40
        cases.append(("tag sha", wrong_tag))

        wrong_release = FakeBackend()
        wrong_release.tags[bundle.index.tag] = bundle.index.source_sha
        wrong_release.releases[bundle.index.tag] = Release(
            tag=bundle.index.tag,
            title="wrong title",
            body=bundle.index.release_body,
            assets={},
        )
        cases.append(("release metadata", wrong_release))

        wrong_asset = FakeBackend()
        wrong_asset.tags[bundle.index.tag] = bundle.index.source_sha
        wrong_asset.releases[bundle.index.tag] = Release(
            tag=bundle.index.tag,
            title=bundle.index.release_title,
            body=bundle.index.release_body,
            assets={ASSET_NAMES[0]: b"wrong"},
        )
        cases.append(("release asset", wrong_asset))

        unexpected_asset = FakeBackend()
        unexpected_asset.tags[bundle.index.tag] = bundle.index.source_sha
        unexpected_asset.releases[bundle.index.tag] = Release(
            tag=bundle.index.tag,
            title=bundle.index.release_title,
            body=bundle.index.release_body,
            assets={"unexpected": b"wrong"},
        )
        cases.append(("release asset name", unexpected_asset))

        wrong_cdn = FakeBackend()
        wrong_cdn.cdn[f"cli/{bundle.index.tag}/{ASSET_NAMES[0]}"] = b"wrong"
        cases.append(("cdn asset", wrong_cdn))

        for label, backend in cases:
            with self.subTest(label=label):
                with self.assertRaises(ReconcileConflict):
                    reconcile(
                        backend,
                        bundle,
                        mode=Mode.NORMAL,
                        bridge_tag=bundle.index.tag,
                    )
                self.assertEqual([], backend.writes)

    def test_pointer_conflicts_fail_before_tag_creation(self) -> None:
        bundle = make_bundle()
        for label, path, body in [
            ("malformed stable", "cli/stable.json", b"not-json"),
            ("newer legacy pointer", "cli/latest.txt", b"v0.4.6\n"),
        ]:
            with self.subTest(label=label):
                backend = FakeBackend()
                backend.cdn[path] = body
                with self.assertRaises(ReconcileConflict):
                    reconcile(
                        backend,
                        bundle,
                        mode=Mode.NORMAL,
                        bridge_tag=bundle.index.tag,
                    )
                self.assertEqual([], backend.writes)

    def test_historical_repair_preserves_a_newer_stable_pointer(self) -> None:
        bundle = make_bundle()
        backend = FakeBackend()
        backend.cdn["cli/stable.json"] = b'{"epoch":1,"version":"v0.0.1"}\n'

        reconcile(backend, bundle, mode=Mode.NORMAL, bridge_tag=bundle.index.tag)

        self.assertEqual(b'{"epoch":1,"version":"v0.0.1"}\n', backend.cdn["cli/stable.json"])
        self.assertNotIn("cdn:cli/stable.json", backend.writes)


class BundleStoreTests(unittest.TestCase):
    def test_bundle_index_rejects_boolean_and_out_of_range_numeric_fields(self) -> None:
        bundle = make_bundle()
        for field, value in [
            ("schema_version", True),
            ("epoch", True),
            ("epoch", 2**32),
        ]:
            with self.subTest(field=field, value=value):
                encoded = bundle.index.as_dict()
                encoded[field] = value
                raw = (json.dumps(encoded, sort_keys=True, separators=(",", ":")) + "\n").encode()
                with self.assertRaises(ReconcileConflict):
                    BundleIndex.decode(raw)

    def test_bundle_index_rejects_invalid_object_identity_types(self) -> None:
        bundle = make_bundle()
        for field, value in [("size", True), ("size", "1"), ("sha256", 1)]:
            with self.subTest(field=field, value=value):
                encoded = bundle.index.as_dict()
                encoded["objects"][ASSET_NAMES[0]][field] = value
                raw = (json.dumps(encoded, sort_keys=True, separators=(",", ":")) + "\n").encode()
                with self.assertRaises(ReconcileConflict):
                    BundleIndex.decode(raw)

    def test_seal_reads_back_assets_and_publishes_the_index_last(self) -> None:
        bundle = make_bundle()
        store = FakeBundleStore()

        digest = seal_bundle(store, bundle, prefix="fx-release-bundles")

        self.assertEqual(bundle.index.digest(), digest)
        self.assertEqual(
            f"fx-release-bundles/releases/{bundle.index.tag}/index.json",
            store.writes[-1],
        )
        self.assertEqual(bundle.objects, load_bundle(
            store,
            bundle.index.tag,
            prefix="fx-release-bundles",
        ).objects)

    def test_seal_reuses_an_identical_partial_or_complete_bundle(self) -> None:
        bundle = make_bundle()
        store = FakeBundleStore()
        first_name = ASSET_NAMES[0]
        first_digest = bundle.index.objects[first_name].sha256
        store.objects[f"fx-release-bundles/objects/{first_digest}"] = bundle.objects[first_name]

        seal_bundle(store, bundle, prefix="fx-release-bundles")
        first_writes = list(store.writes)
        store.writes.clear()
        seal_bundle(store, bundle, prefix="fx-release-bundles")

        self.assertNotIn(f"fx-release-bundles/objects/{first_digest}", first_writes)
        self.assertEqual([], store.writes)

    def test_partial_pre_index_upload_does_not_poison_a_rebuilt_bundle(self) -> None:
        abandoned = make_bundle()
        rebuilt = make_bundle()
        archive_name = ASSET_NAMES[0]
        rebuilt.objects[archive_name] = b"different rebuilt archive"
        checksum_name = f"{archive_name}.sha256"
        rebuilt.objects[checksum_name] = (
            f"{hashlib.sha256(rebuilt.objects[archive_name]).hexdigest()}  {archive_name}\n".encode()
        )
        rebuilt.index = BundleIndex.create(
            tag=rebuilt.index.tag,
            source_sha=rebuilt.index.source_sha,
            epoch=rebuilt.index.epoch,
            release_title=rebuilt.index.release_title,
            release_body=rebuilt.index.release_body,
            objects=rebuilt.objects,
        )
        store = FakeBundleStore()
        abandoned_digest = abandoned.index.objects[archive_name].sha256
        store.objects[f"fx-release-bundles/objects/{abandoned_digest}"] = abandoned.objects[archive_name]

        seal_bundle(store, rebuilt, prefix="fx-release-bundles")

        restored = load_bundle(store, rebuilt.index.tag, prefix="fx-release-bundles")
        self.assertEqual(rebuilt.index, restored.index)
        self.assertEqual(rebuilt.objects, restored.objects)

    def test_seal_rejects_conflicting_private_bytes_without_a_write(self) -> None:
        bundle = make_bundle()
        store = FakeBundleStore()
        digest = bundle.index.objects[ASSET_NAMES[0]].sha256
        path = f"fx-release-bundles/objects/{digest}"
        store.objects[path] = b"wrong"

        with self.assertRaises(ReconcileConflict):
            seal_bundle(store, bundle, prefix="fx-release-bundles")

        self.assertEqual([], store.writes)

    def test_load_rejects_a_pinned_index_digest_mismatch(self) -> None:
        bundle = make_bundle()
        store = FakeBundleStore()
        seal_bundle(store, bundle, prefix="fx-release-bundles")

        with self.assertRaises(ReconcileConflict):
            load_bundle(
                store,
                bundle.index.tag,
                prefix="fx-release-bundles",
                pinned_index_digest="0" * 64,
            )

    def test_corrupt_bundle_fails_before_any_write(self) -> None:
        bundle = make_bundle()
        bundle.objects[ASSET_NAMES[0]] = b"tampered"
        backend = FakeBackend()

        with self.assertRaises(ReconcileConflict):
            reconcile(backend, bundle, mode=Mode.NORMAL, bridge_tag=bundle.index.tag)

        self.assertEqual([], backend.writes)

    def test_post_cleanup_bridge_repair_only_restores_cdn_and_legacy_pointer(self) -> None:
        bundle = make_bundle()
        backend = FakeBackend()
        backend.cdn["cli/stable.json"] = b'{"epoch":1,"version":"v0.0.1"}\n'

        reconcile(
            backend,
            bundle,
            mode=Mode.POST_CLEANUP_BRIDGE,
            bridge_tag=bundle.index.tag,
            pinned_index_digest=bundle.index.digest(),
        )

        self.assertNotIn(bundle.index.tag, backend.tags)
        self.assertNotIn(bundle.index.tag, backend.releases)
        self.assertEqual(b'{"epoch":1,"version":"v0.0.1"}\n', backend.cdn["cli/stable.json"])
        self.assertEqual(b"v0.4.5\n", backend.cdn["cli/latest.txt"])
        self.assertFalse(any(write.startswith("tag:") for write in backend.writes))
        self.assertFalse(any(write.startswith("release:") for write in backend.writes))

    def test_post_cleanup_bridge_repair_rejects_unpinned_or_wrong_identity(self) -> None:
        bundle = make_bundle()
        for pinned, bridge_tag in [
            (None, bundle.index.tag),
            ("0" * 64, bundle.index.tag),
            (bundle.index.digest(), "v0.4.6"),
        ]:
            with self.subTest(pinned=pinned, bridge_tag=bridge_tag):
                backend = FakeBackend()
                with self.assertRaises(ReconcileConflict):
                    reconcile(
                        backend,
                        bundle,
                        mode=Mode.POST_CLEANUP_BRIDGE,
                        bridge_tag=bridge_tag,
                        pinned_index_digest=pinned,
                    )
                self.assertEqual([], backend.writes)


if __name__ == "__main__":
    unittest.main()
