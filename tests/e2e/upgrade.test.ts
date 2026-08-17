import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT } from "../evals/eval-helpers";

const TIMEOUT = 15_000;

function sourceVersion(): string {
  const source = readFileSync(join(REPO_ROOT, "src/main.zig"), "utf8");
  const match = source.match(/pub const version = "([^"]+)";/);
  if (!match) throw new Error("src/main.zig version declaration not found");
  return match[1];
}

function startUpgradeServer(
  root: string,
  options: {
    stableManifest: string | null;
    latest: string;
    artifactVersion?: string;
  },
) {
  const requests: string[] = [];
  let archive: Uint8Array | null = null;
  let checksum = "";
  let archiveRoute = "";

  if (options.artifactVersion) {
    const artifactDir = join(root, "release-artifact");
    const wrapperPath = join(artifactDir, "fx");
    const archivePath = join(root, "fx.tar.gz");
    mkdirSync(artifactDir);
    writeFileSync(wrapperPath, "#!/bin/sh\necho loopback-upgrade-installed\n");
    chmodSync(wrapperPath, 0o755);
    const tar = spawnSync("tar", ["-czf", archivePath, "-C", artifactDir, "fx"]);
    if (tar.status !== 0) throw new Error(tar.stderr.toString());
    archive = readFileSync(archivePath);
    checksum = createHash("sha256").update(archive).digest("hex");
    const targetPlatform = `${process.platform === "darwin" ? "macos" : "linux"}-${process.arch === "arm64" ? "aarch64" : "x86_64"}`;
    archiveRoute = `/${options.artifactVersion}/fx-${targetPlatform}.tar.gz`;
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname;
      requests.push(path);
      if (path === "/stable.json" && options.stableManifest !== null) {
        return new Response(options.stableManifest);
      }
      if (path === "/latest.txt") return new Response(`${options.latest}\n`);
      if (archive !== null && path === archiveRoute) return new Response(archive);
      if (archive !== null && path === `${archiveRoute}.sha256`) {
        return new Response(`${checksum}\n`);
      }
      return new Response("not found", { status: 404 });
    },
  });

  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    requests,
    stop: () => server.stop(true),
  };
}

async function runInstalledFx(path: string, args: string[], env: Record<string, string>) {
  const child = Bun.spawn([path, ...args], {
    env: { ...process.env, ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { stdout, stderr, exitCode };
}

describe("cli: upgrade", () => {
  test(
    "uses the controlled loopback CDN for the epoch manifest and artifacts",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-upgrade-epoch-")));
      const home = join(root, "home");
      const installedFx = join(root, "fx");
      mkdirSync(home);
      copyFileSync(FX_BIN, installedFx);
      chmodSync(installedFx, 0o755);
      const release = startUpgradeServer(root, {
        stableManifest: '{"epoch":1,"version":"v0.0.1"}',
        latest: "v9.9.9",
        artifactVersion: "v0.0.1",
      });

      try {
        const result = await runInstalledFx(installedFx, ["upgrade", "--json"], {
          HOME: home,
          NO_COLOR: "1",
          FX_AUTO_UPGRADE: "0",
          FX_E2E_UPGRADE_BASE_URL: release.baseUrl,
        });
        expect(result.exitCode).toBe(0);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout.trim())).toMatchObject({
          kind: "upgrade",
          current: sourceVersion(),
          latest: "0.0.1",
          status: "upgraded",
        });
        expect(release.requests).toEqual([
          "/stable.json",
          `/v0.0.1/fx-${process.platform === "darwin" ? "macos" : "linux"}-${process.arch === "arm64" ? "aarch64" : "x86_64"}.tar.gz`,
          `/v0.0.1/fx-${process.platform === "darwin" ? "macos" : "linux"}-${process.arch === "arm64" ? "aarch64" : "x86_64"}.tar.gz.sha256`,
        ]);
        expect(readFileSync(installedFx, "utf8")).toContain("loopback-upgrade-installed");
      } finally {
        release.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "falls back to epoch zero and refuses a legacy downgrade",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-upgrade-fallback-")));
      const home = join(root, "home");
      const installedFx = join(root, "fx");
      mkdirSync(home);
      copyFileSync(FX_BIN, installedFx);
      chmodSync(installedFx, 0o755);
      const before = createHash("sha256").update(readFileSync(installedFx)).digest("hex");
      const release = startUpgradeServer(root, {
        stableManifest: '{"epoch":"bad","version":"v0.0.1"}',
        latest: "v0.0.1",
      });

      try {
        const result = await runInstalledFx(installedFx, ["upgrade", "--json"], {
          HOME: home,
          NO_COLOR: "1",
          FX_AUTO_UPGRADE: "0",
          FX_E2E_UPGRADE_BASE_URL: release.baseUrl,
        });
        expect(result.exitCode).toBe(0);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout.trim())).toMatchObject({
          kind: "upgrade",
          latest: "0.0.1",
          status: "up_to_date",
        });
        expect(release.requests).toEqual(["/stable.json", "/latest.txt"]);
        const after = createHash("sha256").update(readFileSync(installedFx)).digest("hex");
        expect(after).toBe(before);
      } finally {
        release.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
