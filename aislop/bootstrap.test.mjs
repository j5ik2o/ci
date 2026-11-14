/**
 * 起動役（aislop/bootstrap.mjs）のテスト。正本のテスト（check-aislop.test.mjs）
 * と違い、こちらは j5ik2o/ci の中だけで回す。呼び出し側へは配らない
 * （pin の対象は check-aislop.mjs と check-aislop.test.mjs の2つだけ）。
 */
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  FETCH_TIMEOUT_MS,
  RUN_TIMEOUT_MS,
  childTimeoutMs,
  remainingBudgetMs,
  runPinnedCommand,
  writeVerifiedCache,
} from "./bootstrap.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const bootstrapUrl = pathToFileURL(path.join(here, "bootstrap.mjs")).href;

describe("writeVerifiedCache（issue #21）", () => {
  it("照合済みの内容をキャッシュへ置き、一時ファイルを残さない", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-cache-"));
    try {
      const buffer = Buffer.from("正本の内容\n".repeat(1000));
      const cachePath = writeVerifiedCache(dir, "check-aislop.mjs", buffer);
      assert.equal(cachePath, path.join(dir, "check-aislop.mjs"));
      assert.deepEqual(readFileSync(cachePath), buffer);
      assert.deepEqual(readdirSync(dir), ["check-aislop.mjs"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("並行する書き込みでもキャッシュは壊れず、一時ファイルが残らない", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-cache-race-"));
    try {
      const buffer = Buffer.alloc(1024 * 1024, "x");
      const bufferPath = path.join(dir, "buffer.bin");
      writeFileSync(bufferPath, buffer);
      const driverPath = path.join(dir, "driver.mjs");
      writeFileSync(
        driverPath,
        [
          `const m = await import(${JSON.stringify(bootstrapUrl)});`,
          `import { readFileSync } from "node:fs";`,
          `const buffer = readFileSync(process.argv[2]);`,
          `for (let i = 0; i < 5; i += 1) {`,
          `  m.writeVerifiedCache(process.argv[3], "check-aislop.mjs", buffer);`,
          `}`,
        ].join("\n"),
      );
      const cacheDir = path.join(dir, "cache");
      // spawnSync では1つずつ終わるのを待ってしまい同時書き込みにならない。
      // 全プロセスを先に起動し、終了をまとめて待つ。
      const runDriver = () =>
        new Promise((resolvePromise, reject) => {
          const child = spawn(
            process.execPath,
            [driverPath, bufferPath, cacheDir],
            { stdio: ["ignore", "pipe", "pipe"] },
          );
          let stderr = "";
          child.stderr.on("data", (chunk) => {
            stderr += chunk;
          });
          child.on("error", reject);
          child.on("close", (code) => resolvePromise({ code, stderr }));
        });
      const children = await Promise.all(
        Array.from({ length: 4 }, () => runDriver()),
      );
      for (const child of children) {
        assert.equal(child.code, 0, child.stderr);
      }
      assert.deepEqual(
        readFileSync(path.join(cacheDir, "check-aislop.mjs")),
        buffer,
      );
      assert.deepEqual(readdirSync(cacheDir), ["check-aislop.mjs"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("制限時間（issue #20）", () => {
  it("全体予算から経過を引いた残り時間を子へ渡す", () => {
    assert.equal(remainingBudgetMs(660_000, 1_000, 46_000), 615_000);
    assert.equal(remainingBudgetMs(660_000, 1_000, 661_000), 0);
    assert.ok(remainingBudgetMs(660_000, 1_000, 700_000) < 0);
  });

  it("子プロセスの制限時間は既定660秒で、正の整数だけで上書きできる", () => {
    assert.equal(RUN_TIMEOUT_MS, 660_000);
    assert.equal(FETCH_TIMEOUT_MS, 60_000);
    assert.equal(childTimeoutMs({}), 660_000);
    assert.equal(
      childTimeoutMs({ AISLOP_CHECK_RUN_TIMEOUT_MS: "1234" }),
      1234,
    );
    for (const bad of ["abc", "0", "-5", "1.5", ""]) {
      assert.equal(
        childTimeoutMs({ AISLOP_CHECK_RUN_TIMEOUT_MS: bad }),
        660_000,
        `AISLOP_CHECK_RUN_TIMEOUT_MS=${bad} は既定に戻る`,
      );
    }
  });

  it("runPinnedCommand は終了コードをそのまま返し、止まった子は制限時間で落とす", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-run-"));
    try {
      const exit3 = path.join(dir, "exit3.mjs");
      writeFileSync(exit3, "process.exit(3);\n");
      assert.equal(
        await runPinnedCommand([exit3], {
          cwd: dir,
          env: process.env,
          timeoutMs: 10_000,
        }),
        3,
      );
      const sleeper = path.join(dir, "sleeper.mjs");
      writeFileSync(sleeper, "setTimeout(() => {}, 30_000);\n");
      const started = Date.now();
      const code = await runPinnedCommand([sleeper], {
        cwd: dir,
        env: process.env,
        timeoutMs: 200,
      });
      const elapsed = Date.now() - started;
      assert.equal(code, 1);
      assert.ok(elapsed < 10_000, `制限時間200ミリ秒に対し ${elapsed} ミリ秒かかった`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // 寝続ける孫プロセスを起動し、その pid をファイルへ書く子スクリプト。
  const writeGrandchildDriver = (dir) => {
    const driver = path.join(dir, "driver.mjs");
    writeFileSync(
      driver,
      [
        'import { spawn } from "node:child_process";',
        'import { writeFileSync } from "node:fs";',
        'import path from "node:path";',
        'const gc = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { stdio: "ignore" });',
        'writeFileSync(path.join(process.cwd(), "grandchild.pid"), String(gc.pid));',
        "setTimeout(() => {}, 30_000);",
        "",
      ].join("\n"),
    );
    return driver;
  };
  const isAlive = (pid) => {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  };
  const waitUntilDead = async (pid, limitMs = 5_000) => {
    const deadline = Date.now() + limitMs;
    while (isAlive(pid) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 100));
    }
    return !isAlive(pid);
  };

  it("制限時間の超過で、子の孫プロセスも残らない", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-tree-"));
    try {
      const driver = writeGrandchildDriver(dir);
      const code = await runPinnedCommand([driver], {
        cwd: dir,
        env: process.env,
        timeoutMs: 500,
      });
      assert.equal(code, 1);
      const grandchildPid = Number(
        readFileSync(path.join(dir, "grandchild.pid"), "utf8"),
      );
      assert.ok(
        await waitUntilDead(grandchildPid),
        `孫プロセス ${grandchildPid} が制限時間の後も残っている`,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("起動役が SIGTERM を受けたら、子の孫プロセスも残らない", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-tree-sig-"));
    try {
      const childDriver = writeGrandchildDriver(dir);
      // runPinnedCommand を回すだけの起動役役のプロセス。
      const runner = path.join(dir, "runner.mjs");
      writeFileSync(
        runner,
        [
          `const m = await import(${JSON.stringify(bootstrapUrl)});`,
          `await m.runPinnedCommand([process.argv[2]], {`,
          `  cwd: process.cwd(),`,
          `  env: process.env,`,
          `  timeoutMs: 30_000,`,
          `});`,
        ].join("\n"),
      );
      const proc = spawn(process.execPath, [runner, childDriver], {
        cwd: dir,
        stdio: ["ignore", "pipe", "pipe"],
      });
      const closed = new Promise((r) => proc.on("close", r));
      const pidFile = path.join(dir, "grandchild.pid");
      const deadline = Date.now() + 5_000;
      while (!existsSync(pidFile) && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 50));
      }
      assert.ok(existsSync(pidFile), "子が孫プロセスを起動しなかった");
      const grandchildPid = Number(readFileSync(pidFile, "utf8"));
      proc.kill("SIGTERM");
      await closed;
      assert.ok(
        await waitUntilDead(grandchildPid),
        `孫プロセス ${grandchildPid} が SIGTERM の後も残っている`,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("import しても main は走らない（entry guard）", () => {
    assert.ok(existsSync(path.join(here, "bootstrap.mjs")));
    // このテストファイル自体が bootstrap.mjs を import して import できている
    // ことが、entry guard の証拠になる（main が走れば process.exit する）。
  });
});
