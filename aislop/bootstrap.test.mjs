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
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  FETCH_TIMEOUT_MS,
  RUN_TIMEOUT_MS,
  TREE_KILL_GRACE_MS,
  assertCacheDirOutsideRoot,
  cacheRootDir,
  childTimeoutMs,
  fetchTimeoutMs,
  remainingBudgetMs,
  runPinnedCommand,
  writeVerifiedCache,
} from "./bootstrap.mjs";
import { TREE_KILL_GRACE_MS as CHECKER_TREE_KILL_GRACE_MS } from "./check-aislop.mjs";

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

describe("キャッシュの置き場所", () => {
  it("AISLOP_CHECK_CACHE_DIR の指定が最優先で、XDG_CACHE_HOME より先に効く", () => {
    assert.equal(
      cacheRootDir({
        AISLOP_CHECK_CACHE_DIR: "/somewhere/cache",
        XDG_CACHE_HOME: "/xdg",
      }),
      "/somewhere/cache",
    );
  });

  it("XDG_CACHE_HOME があれば、その配下の aislop-check になる", () => {
    assert.equal(
      cacheRootDir({ XDG_CACHE_HOME: "/xdg" }),
      path.join("/xdg", "aislop-check"),
    );
  });

  it("指定が無ければ、ホーム配下の .cache の中の aislop-check になる", () => {
    assert.equal(
      cacheRootDir({}),
      path.join(homedir(), ".cache", "aislop-check"),
    );
  });

  it("リポジトリの中（node_modules や直下）には置かない", () => {
    for (const env of [
      {},
      { XDG_CACHE_HOME: "/xdg" },
      { AISLOP_CHECK_CACHE_DIR: "/somewhere/cache" },
    ]) {
      const root = cacheRootDir(env);
      assert.ok(path.isAbsolute(root));
      assert.ok(!root.split(path.sep).includes("node_modules"));
    }
  });

  it("相対パスの指定は、絶対パスへ解決してから返す（issue #31）", () => {
    const fromEnv = cacheRootDir({ AISLOP_CHECK_CACHE_DIR: "relative-cache" });
    assert.ok(path.isAbsolute(fromEnv));
    assert.equal(fromEnv, path.resolve("relative-cache"));
    const fromXdg = cacheRootDir({ XDG_CACHE_HOME: "relative-xdg" });
    assert.ok(path.isAbsolute(fromXdg));
    assert.equal(fromXdg, path.resolve("relative-xdg", "aislop-check"));
  });

  it("置き場所がリポジトリの中なら失敗し、外なら通る（issue #31）", () => {
    const root = path.join(path.sep, "work", "repo");
    for (const inside of [
      root,
      path.join(root, ".aislop-check"),
      path.join(root, "sub", "cache"),
    ]) {
      assert.throws(
        () => assertCacheDirOutsideRoot(inside, root),
        /リポジトリの中になっています/,
        `${inside} はリポジトリの中`,
      );
    }
    for (const outside of [
      path.join(path.sep, "work", "cache"),
      path.join(path.sep, "work", "repo2", "cache"),
      path.join(path.sep, "cache"),
    ]) {
      assertCacheDirOutsideRoot(outside, root);
    }
  });

  it("パスの途中のシンボリックリンクを解決してから判定する（issue #31）", () => {
    const base = mkdtempSync(path.join(tmpdir(), "aislop-link-"));
    try {
      const realRoot = mkdtempSync(path.join(base, "repo-"));
      const linkRoot = path.join(base, "link-repo");
      symlinkSync(realRoot, linkRoot, "dir");
      assert.throws(
        () => assertCacheDirOutsideRoot(path.join(linkRoot, "inner"), realRoot),
        /リポジトリの中になっています/,
      );
      assert.throws(
        () => assertCacheDirOutsideRoot(path.join(realRoot, "inner"), linkRoot),
        /リポジトリの中になっています/,
      );
      const realOutside = mkdtempSync(path.join(base, "outside-"));
      const linkOutside = path.join(base, "link-outside");
      symlinkSync(realOutside, linkOutside, "dir");
      assertCacheDirOutsideRoot(linkOutside, realRoot);
    } finally {
      rmSync(base, { recursive: true, force: true });
    }
  });

  it("リポジトリ内の判定は、相対パスで与えても解決してから行う（issue #31）", () => {
    const root = process.cwd();
    assert.throws(
      () => assertCacheDirOutsideRoot(".", root),
      /リポジトリの中になっています/,
    );
    assert.throws(
      () => assertCacheDirOutsideRoot(path.join("sub", "cache"), root),
      /リポジトリの中になっています/,
    );
    assertCacheDirOutsideRoot(path.join("..", "outside-cache"), root);
  });
});

describe("制限時間（issue #20）", () => {
  it("全体予算から経過を引いた残り時間を子へ渡す", () => {
    assert.equal(remainingBudgetMs(660_000, 1_000, 46_000), 615_000);
    assert.equal(remainingBudgetMs(660_000, 1_000, 661_000), 0);
    assert.ok(remainingBudgetMs(660_000, 1_000, 700_000) < 0);
  });

  it("取得の制限時間は、固定の60秒と全体予算の残り時間の小さい方にする（issue #25）", () => {
    assert.equal(fetchTimeoutMs(120_000), FETCH_TIMEOUT_MS);
    assert.equal(fetchTimeoutMs(30_000), 30_000);
    assert.equal(fetchTimeoutMs(0), 0);
    assert.equal(fetchTimeoutMs(-1), 0);
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

  it("直接の子が先に終わっても、SIGTERM を無視する孫は強制終了で残らない（issue #24）", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-tree-stubborn-"));
    try {
      // 子は、SIGTERM を無視する孫を同じグループに起動してから寝続ける。
      // 制限時間で子へ SIGTERM が届くと子は死ぬが、孫は残ろうとする。
      const child = path.join(dir, "child.mjs");
      writeFileSync(
        child,
        [
          'import { spawn } from "node:child_process";',
          'import { writeFileSync } from "node:fs";',
          'import path from "node:path";',
          'const gc = spawn(process.execPath, ["-e", "process.on(\'SIGTERM\', () => {}); setTimeout(() => {}, 30000)"], { stdio: "ignore" });',
          'writeFileSync(path.join(process.cwd(), "grandchild.pid"), String(gc.pid));',
          "setTimeout(() => {}, 30_000);",
          "",
        ].join("\n"),
      );
      const code = await runPinnedCommand([child], {
        cwd: dir,
        env: process.env,
        timeoutMs: 300,
        graceMs: 500,
      });
      assert.equal(code, 1);
      const grandchildPid = Number(
        readFileSync(path.join(dir, "grandchild.pid"), "utf8"),
      );
      assert.ok(
        await waitUntilDead(grandchildPid),
        `孫プロセス ${grandchildPid} が強制終了の予約の解除で残っている`,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("シグナル転送では子の後始末が済むため、別グループの孫も残らない（issue #23）", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-tree-forward-"));
    try {
      // 検査を模した子: 別グループで孫を起動し、SIGTERM を受けたら
      // 孫のグループを終了してから終わる。起動役が即 SIGKILL すると、
      // この後始末が走らず孫が残る。
      const child = path.join(dir, "checker-like.mjs");
      writeFileSync(
        child,
        [
          'import { spawn } from "node:child_process";',
          'import { writeFileSync } from "node:fs";',
          'import path from "node:path";',
          'const gc = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { stdio: "ignore", detached: true });',
          'writeFileSync(path.join(process.cwd(), "grandchild.pid"), String(gc.pid));',
          'process.on("SIGTERM", () => {',
          '  try { process.kill(-gc.pid, "SIGKILL"); } catch {}',
          "  process.exit(0);",
          "});",
          "setTimeout(() => {}, 30_000);",
          "",
        ].join("\n"),
      );
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
      const proc = spawn(process.execPath, [runner, child], {
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
        `孫プロセス ${grandchildPid} がシグナル転送の即 SIGKILL で残っている`,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("終了の層の順序と全体タイマー（プルリクエスト #26 のレビュー指摘）", () => {
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

  // 検査を模した子: 別グループで SIGTERM を無視する孫を起動し、SIGTERM を
  // 受けたら孫のグループへ信号を転送し、検査自身の猶予を模した1.5秒の
  // 遅れの後に孫のグループを強制終了してから終わる。起動役の猶予が
  // この遅れ以下だと、起動役が先に子を強制終了し、孫が残る。
  const writeDelayedChecker = (dir) => {
    const child = path.join(dir, "delayed-checker.mjs");
    writeFileSync(
      child,
      [
        'import { spawn } from "node:child_process";',
        'import { writeFileSync } from "node:fs";',
        'import path from "node:path";',
        'const gc = spawn(process.execPath, ["-e", "process.on(\'SIGTERM\', () => {}); setTimeout(() => {}, 30000)"], { stdio: "ignore", detached: true });',
        'writeFileSync(path.join(process.cwd(), "grandchild.pid"), String(gc.pid));',
        'process.on("SIGTERM", () => {',
        '  try { process.kill(-gc.pid, "SIGTERM"); } catch {}',
        "  setTimeout(() => {",
        '    try { process.kill(-gc.pid, "SIGKILL"); } catch {}',
        "    process.exit(0);",
        "  }, 1_500);",
        "});",
        "setTimeout(() => {}, 30_000);",
        "",
      ].join("\n"),
    );
    return child;
  };

  it("起動役の猶予は、検査の猶予より十分長い", () => {
    assert.ok(
      TREE_KILL_GRACE_MS > CHECKER_TREE_KILL_GRACE_MS + 2_000,
      `起動役の猶予 ${TREE_KILL_GRACE_MS} ミリ秒は、検査の猶予 ${CHECKER_TREE_KILL_GRACE_MS} ミリ秒より十分長くなければならない`,
    );
  });

  it("制限時間の超過でも、後始末に時間のかかる検査の下の孫は残らない", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-tree-layered-"));
    try {
      const child = writeDelayedChecker(dir);
      const code = await runPinnedCommand([child], {
        cwd: dir,
        env: process.env,
        timeoutMs: 300,
        graceMs: 3_000,
      });
      assert.equal(code, 1);
      const grandchildPid = Number(
        readFileSync(path.join(dir, "grandchild.pid"), "utf8"),
      );
      assert.ok(
        await waitUntilDead(grandchildPid),
        `孫プロセス ${grandchildPid} が、起動役の先行した強制終了で残っている`,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("起動役が SIGTERM を受けても、後始末に時間のかかる検査の下の孫は残らない", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-tree-layered-sig-"));
    try {
      const child = writeDelayedChecker(dir);
      const runner = path.join(dir, "runner.mjs");
      writeFileSync(
        runner,
        [
          `const m = await import(${JSON.stringify(bootstrapUrl)});`,
          `await m.runPinnedCommand([process.argv[2]], {`,
          `  cwd: process.cwd(),`,
          `  env: process.env,`,
          `  timeoutMs: 30_000,`,
          `  graceMs: 3_000,`,
          `});`,
        ].join("\n"),
      );
      const proc = spawn(process.execPath, [runner, child], {
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
        `孫プロセス ${grandchildPid} が、起動役の先行した強制終了で残っている`,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // 全体タイマーが残る起動役役のプロセスを作る。制限時間と猶予は、
  // テストごとに変えられるよう引数で受ける。
  const writeRunner = (dir, timeoutMs) => {
    const runner = path.join(dir, "runner.mjs");
    writeFileSync(
      runner,
      [
        `const m = await import(${JSON.stringify(bootstrapUrl)});`,
        `await m.runPinnedCommand([process.argv[2]], {`,
        `  cwd: process.cwd(),`,
        `  env: process.env,`,
        `  timeoutMs: ${timeoutMs},`,
        `  graceMs: 3_000,`,
        `});`,
      ].join("\n"),
    );
    return runner;
  };
  const runUntilGrandchild = async (dir, runner, child) => {
    const proc = spawn(process.execPath, [runner, child], {
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
    return { proc, closed, grandchildPid: Number(readFileSync(pidFile, "utf8")) };
  };

  it("信号を転送したら全体タイマーは解除され、子の後始末は中断しない", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-tree-timer-"));
    try {
      const child = writeDelayedChecker(dir);
      const runner = writeRunner(dir, 800);
      const { proc, closed, grandchildPid } = await runUntilGrandchild(
        dir,
        runner,
        child,
      );
      // 全体タイマー（800ミリ秒）が切れる前に信号を送る。タイマーが
      // 残っていると、切れ目に SIGTERM が再送され、受け手を外した子が
      // 既定動作で死んで、1.5秒かかる後始末が中断する。
      proc.kill("SIGTERM");
      await closed;
      assert.ok(
        await waitUntilDead(grandchildPid),
        `孫プロセス ${grandchildPid} が、全体タイマーの再送した信号で残っている`,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("制限時間の超過の後に信号を受けても、子の後始末は中断しない", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "aislop-tree-timer2-"));
    try {
      const child = writeDelayedChecker(dir);
      const runner = writeRunner(dir, 300);
      const { proc, closed, grandchildPid } = await runUntilGrandchild(
        dir,
        runner,
        child,
      );
      // 制限時間（300ミリ秒）が切れて、子が後始末（1.5秒）を始めた後に
      // 信号を送る。既に送った SIGTERM を再送すると、受け手を外した子が
      // 既定動作で死んで後始末が中断する。
      await new Promise((r) => setTimeout(r, 600));
      proc.kill("SIGTERM");
      await closed;
      assert.ok(
        await waitUntilDead(grandchildPid),
        `孫プロセス ${grandchildPid} が、転送の再送した信号で残っている`,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
