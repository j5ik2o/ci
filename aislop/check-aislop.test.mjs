import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import {
  AISLOP_ENV,
  TOOL_SPECIFIERS,
  assertBiomeRuns,
  assertReportShape,
  checkCoverage,
  checkEngines,
  checkReport,
  compareFindings,
  createProbeTool,
  findUnresolvableTools,
  resolveConfig,
  runChecks,
  scan,
  scanFileCount,
} from "./check-aislop.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const config = resolveConfig([], process.env);

const createFinding = (overrides = {}) => ({
  engine: "code-quality",
  rule: "complexity/file-too-large",
  file: "scripts/example.py",
  message: "File too large",
  ...overrides,
});

const createDiagnostic = (overrides = {}) => ({
  engine: "code-quality",
  rule: "complexity/file-too-large",
  filePath: "scripts/example.py",
  message: "File too large",
  severity: "warning",
  line: 0,
  ...overrides,
});

const createAccepted = (findings) => [{ reason: "理由", findings }];

const diagnosticOf = (finding) =>
  createDiagnostic({
    engine: finding.engine,
    rule: finding.rule,
    filePath: finding.file,
    message: finding.message,
  });

describe("resolveConfig", () => {
  it("既定ではカレントディレクトリをルートにし、一覧と aislop 本体をその下に置く", () => {
    const resolved = resolveConfig([], {}, "/repo");
    assert.equal(resolved.root, "/repo");
    assert.equal(resolved.acceptedPath, "/repo/scripts/aislop-accepted.json");
    assert.equal(resolved.aislopCli, "/repo/node_modules/aislop/dist/cli.js");
  });

  it("引数が環境変数より優先し、環境変数が既定より優先する", () => {
    const byEnv = resolveConfig(
      [],
      { AISLOP_CHECK_ROOT: "/env-root", AISLOP_CHECK_ACCEPTED: "env.json" },
      "/repo",
    );
    assert.equal(byEnv.root, "/env-root");
    assert.equal(byEnv.acceptedPath, "/env-root/env.json");
    const byArg = resolveConfig(
      ["--root", "/arg-root", "--accepted", "/abs/list.json"],
      { AISLOP_CHECK_ROOT: "/env-root" },
      "/repo",
    );
    assert.equal(byArg.root, "/arg-root");
    assert.equal(byArg.acceptedPath, "/abs/list.json");
  });
});

describe("compareFindings", () => {
  it("一覧にある指摘だけなら、行が変わっても一覧も解消も出さない", () => {
    const result = compareFindings(
      createAccepted([createFinding()]),
      [createDiagnostic({ line: 12 })],
    );
    assert.deepEqual(result, { unlisted: [], resolved: [] });
  });

  it("一覧に無い warn と error を、行番号付きで一覧に無い指摘として返す", () => {
    const finding = createFinding();
    const result = compareFindings(createAccepted([finding]), [
      createDiagnostic(),
      createDiagnostic({ rule: "security/new-function", severity: "error", line: 3 }),
      createDiagnostic({ message: "File too large (other)", line: 5 }),
    ]);
    assert.deepEqual(result.unlisted, [
      { ...finding, rule: "security/new-function", line: 3 },
      { ...finding, message: "File too large (other)", line: 5 },
    ]);
    assert.deepEqual(result.resolved, []);
  });

  it("同じ指摘が一覧の数より多く出たら、超えた分だけを一覧に無い指摘として返す", () => {
    const finding = createFinding();
    const result = compareFindings(createAccepted([finding]), [
      createDiagnostic({ line: 1 }),
      createDiagnostic({ line: 2 }),
    ]);
    assert.deepEqual(result.unlisted, [{ ...finding, line: 2 }]);
    assert.deepEqual(result.resolved, []);
  });

  it("同じ指摘が一覧と同じ数だけ出たら、同数として受け入れる", () => {
    const finding = createFinding();
    const result = compareFindings(createAccepted([finding, finding]), [
      createDiagnostic({ line: 1 }),
      createDiagnostic({ line: 2 }),
    ]);
    assert.deepEqual(result, { unlisted: [], resolved: [] });
  });

  it("規則・ファイル・文言が同じでもエンジンが違えば別の指摘とみなす", () => {
    const finding = createFinding();
    const result = compareFindings(createAccepted([finding]), [
      createDiagnostic({ engine: "lint" }),
    ]);
    assert.deepEqual(result.unlisted, [{ ...finding, engine: "lint", line: 0 }]);
    assert.deepEqual(result.resolved, [finding]);
  });

  it("info の指摘は一覧に無くても報告しない", () => {
    const result = compareFindings([], [createDiagnostic({ severity: "info" })]);
    assert.deepEqual(result.unlisted, []);
  });

  it("一覧にあるのに出なくなった指摘を解消として返す", () => {
    const finding = createFinding();
    assert.deepEqual(compareFindings(createAccepted([finding]), []).resolved, [finding]);
  });

  it("行番号だけが違う指摘は一致し、文言が違えば一致しない（行番号を見ない照合）", () => {
    const finding = createFinding();
    const byLine = compareFindings(createAccepted([finding]), [
      createDiagnostic({ line: 9999 }),
    ]);
    assert.deepEqual(byLine, { unlisted: [], resolved: [] });
    const byMessage = compareFindings(createAccepted([finding]), [
      createDiagnostic({ message: "File too large (limit: 400)" }),
    ]);
    assert.deepEqual(byMessage.unlisted, [
      { ...finding, message: "File too large (limit: 400)", line: 0 },
    ]);
    assert.deepEqual(byMessage.resolved, [finding]);
  });
});

describe("findUnresolvableTools", () => {
  it("すべて解決できれば何も返さない", () => {
    assert.deepEqual(findUnresolvableTools(() => "/resolved"), []);
  });

  it("解決できない道具の名前を TOOL_SPECIFIERS の名前で返す", () => {
    const resolve = (specifier) => {
      if (specifier.startsWith("@biomejs/") || specifier === "knip") {
        throw new Error("MODULE_NOT_FOUND");
      }
      return "/resolved";
    };
    assert.deepEqual(findUnresolvableTools(resolve), ["@biomejs/biome", "knip"]);
  });

  it("aislop が resolve に渡す指定子で問い合わせる", () => {
    const seen = [];
    findUnresolvableTools((specifier) => {
      seen.push(specifier);
      return "/resolved";
    });
    assert.deepEqual(seen, Object.values(TOOL_SPECIFIERS));
  });
});

describe("createProbeTool", () => {
  it("Node の道具は、resolve できなければ未導入を確認できたことにする", () => {
    const probe = createProbeTool({
      resolve: () => {
        throw new Error("MODULE_NOT_FOUND");
      },
      runVersion: () => ({ status: 0 }),
    });
    assert.equal(probe("oxlint"), true);
    const present = createProbeTool({
      resolve: () => "/resolved",
      runVersion: () => ({ status: 0 }),
    });
    assert.equal(present("oxlint"), false);
  });

  it("実行ファイルの道具は、--version が起動できなければ未導入を確認できたことにする", () => {
    const absent = createProbeTool({
      resolve: () => "/resolved",
      runVersion: () => ({ error: new Error("spawn ruff ENOENT") }),
    });
    assert.equal(absent("ruff"), true);
    const present = createProbeTool({
      resolve: () => "/resolved",
      runVersion: () => ({ status: 0 }),
    });
    assert.equal(present("ruff"), false);
  });

  it("確かめる方法が無い道具は、未導入を確認できないものとして扱う", () => {
    const probe = createProbeTool({
      resolve: () => "/resolved",
      runVersion: () => ({ status: 0 }),
    });
    assert.equal(probe("unknown-tool"), false);
  });
});

describe("scanFileCount と checkCoverage（空振りを防ぐ確認1）", () => {
  it("coverage.supportedFiles を優先し、無ければ summary.files を使う", () => {
    assert.equal(
      scanFileCount({ coverage: { supportedFiles: 170 }, summary: { files: 3 } }),
      170,
    );
    assert.equal(scanFileCount({ summary: { files: 170 } }), 170);
    assert.equal(scanFileCount({}), null);
    assert.equal(scanFileCount({ coverage: { supportedFiles: "170" } }), null);
  });

  it("対象が1件以上あれば通す", () => {
    assert.equal(checkCoverage({ coverage: { supportedFiles: 170 } }), null);
  });

  it("対象が0件なら、空振りとして問題にする", () => {
    assert.match(checkCoverage({ coverage: { supportedFiles: 0 } }), /対象ファイルが 0 件/);
    assert.match(checkCoverage({ summary: { files: 0 } }), /対象ファイルが 0 件/);
  });

  it("対象ファイル数を確認できなければ、空振りの疑いとして問題にする", () => {
    assert.match(checkCoverage({}), /対象ファイル数を確認できません/);
  });
});

describe("checkEngines", () => {
  const absent = () => true;
  const present = () => false;
  const createList = () => ({
    engines: ["lint", "security"],
    missingToolsAllowed: { ruff: "Python の道具が環境に無い" },
    accepted: [],
  });

  it("一覧のエンジンが全部動き、欠けた道具が許したものだけなら何も返さない", () => {
    const problems = checkEngines(
      createList(),
      { lint: { skipped: false, missingTools: ["ruff"] }, security: { skipped: false } },
      [],
      present,
    );
    assert.deepEqual(problems, []);
  });

  it("設定で外されて scan に出ないエンジンを挙げる", () => {
    const problems = checkEngines(createList(), { lint: { skipped: false } }, [], present);
    assert.equal(problems.length, 1);
    assert.equal(problems[0].engine, "security");
    assert.match(problems[0].reason, /^動いていません/);
  });

  it("許していない欠けた道具を問題として挙げる", () => {
    const problems = checkEngines(
      createList(),
      { lint: { skipped: false, missingTools: ["oxlint"] }, security: { skipped: false } },
      [],
      present,
    );
    assert.deepEqual(problems.map((p) => p.engine), ["lint"]);
    assert.match(problems[0].reason, /^道具 oxlint が見つかりません/);
  });

  it("skipped でも、欠けた道具が許可済みで未導入を確認できれば、停止と見なさない", () => {
    const list = createList();
    list.engines = ["format", "lint"];
    const problems = checkEngines(
      list,
      { format: { skipped: true, missingTools: ["ruff"] }, lint: { skipped: false } },
      [],
      absent,
    );
    assert.deepEqual(problems, []);
  });

  it("skipped で、欠けた道具の未導入を確かめられなければ、停止の疑いとして挙げる", () => {
    const list = createList();
    list.engines = ["format", "lint"];
    const problems = checkEngines(
      list,
      { format: { skipped: true, missingTools: ["ruff"] }, lint: { skipped: false } },
      [],
      present,
    );
    assert.equal(problems.length, 1);
    assert.equal(problems[0].engine, "format");
    assert.match(problems[0].reason, /未導入を、検査側で確かめられませんでした/);
  });

  it("skipped で、欠けた道具が許可されていなければ、停止の疑いとして挙げる", () => {
    const list = createList();
    list.engines = ["format", "lint"];
    const problems = checkEngines(
      list,
      { format: { skipped: true, missingTools: ["oxlint"] }, lint: { skipped: false } },
      [],
      absent,
    );
    assert.equal(problems.length, 1);
    assert.match(problems[0].reason, /欠落が許可されていません/);
  });

  it("skipped で、欠けた道具の記録が無ければ、確かめられないものとして挙げる", () => {
    const list = createList();
    list.engines = ["format", "lint"];
    const problems = checkEngines(
      list,
      { format: { skipped: true }, lint: { skipped: false } },
      [],
      absent,
    );
    assert.equal(problems.length, 1);
    assert.match(problems[0].reason, /欠けた道具の記録が無いため/);
  });

  it("一覧にあるエンジンの指摘がすべて出なくなったら、道具停止の疑いとして挙げる", () => {
    const list = createList();
    list.accepted = [{ reason: "理由", findings: [createFinding({ engine: "lint" })] }];
    const problems = checkEngines(
      list,
      { lint: { skipped: false }, security: { skipped: false } },
      [createFinding({ engine: "lint" })],
      present,
    );
    assert.equal(problems.length, 1);
    assert.equal(problems[0].engine, "lint");
    assert.match(problems[0].reason, /一覧にある指摘 1 件がすべて出なくなりました/);
  });

  it("一部だけ出なくなったら道具停止の疑いは挙げない", () => {
    const list = createList();
    const kept = createFinding({ engine: "lint", file: "a.py" });
    const gone = createFinding({ engine: "lint", file: "b.py" });
    list.accepted = [{ reason: "理由", findings: [kept, gone] }];
    const problems = checkEngines(
      list,
      { lint: { skipped: false }, security: { skipped: false } },
      [gone],
      present,
    );
    assert.deepEqual(problems, []);
  });
});

describe("assertReportShape", () => {
  it("読める形なら何もしない", () => {
    assert.doesNotThrow(() =>
      assertReportShape({ schemaVersion: "1", engines: {}, diagnostics: [] }),
    );
  });

  it("schemaVersion が違う、engines や diagnostics が無いときは、何が違うかを書いて投げる", () => {
    assert.throws(
      () => assertReportShape({ schemaVersion: 1, cliVersion: "0.99.0" }),
      /aislop@0\.99\.0[\s\S]*schemaVersion が 1[\s\S]*engines がありません[\s\S]*diagnostics が配列ではありません/,
    );
  });
});

describe("main の失敗終端（spawnSync の結果を差し替えて観測する）", () => {
  const okReport = { schemaVersion: "1", cliVersion: "0.20.1", engines: {}, diagnostics: [] };

  it("biome の起動が終了コード 0 なら throw しない", () => { assert.doesNotThrow(() => assertBiomeRuns({ status: 0, stderr: "" })); });

  it("biome の起動が終了コード 0 でなければ、biome の名前と終了コードを含む Error を投げる", () => {
    assert.throws(() => assertBiomeRuns({ status: 1, stderr: "boom" }), /biome を起動できません（終了コード 1）[\s\S]*boom/);
  });

  it("aislop の起動自体が失敗したら理由付きで throw する", () => { assert.throws(() => scan({ error: new Error("spawn ENOENT") }), /aislop を起動できませんでした: spawn ENOENT/); });

  it("scan の出力が JSON として読めなければ、終了コードと stderr を含む Error を投げる", () => {
    assert.throws(() => scan({ stdout: "not json", status: 1, stderr: "boom" }), /aislop scan --json の出力を読めませんでした（終了コード 1）[\s\S]*boom/);
  });

  it("scan の出力の形が想定と違えば、schemaVersion の値を示して throw する", () => {
    const stdout = JSON.stringify({ schemaVersion: "2", engines: {}, diagnostics: [] });
    assert.throws(() => scan({ stdout, status: 0 }), /想定と違います[\s\S]*schemaVersion が "2"/);
  });

  it("scan の出力が読める形なら report をそのまま返す", () => { assert.deepEqual(scan({ stdout: JSON.stringify(okReport), status: 0 }), okReport); });
});

describe("runChecks（main の結線）", () => {
  const okReport = {
    schemaVersion: "1",
    cliVersion: "0.20.1",
    engines: {},
    diagnostics: [],
    coverage: { supportedFiles: 1 },
  };
  const okScan = () => ({ stdout: JSON.stringify(okReport), status: 0 });
  const baseDeps = {
    readList: () => ({ engines: [], missingToolsAllowed: {}, accepted: [] }),
    resolve: () => "/resolved",
    runBiome: () => ({ status: 0 }),
    runScan: okScan,
    probeTool: () => false,
    acceptedLabel: "scripts/aislop-accepted.json",
    logSuccess: () => {},
    logFailure: () => {},
  };
  const createDeps = (overrides = {}) => ({ ...baseDeps, ...overrides });
  it("道具の resolve が失敗したら、道具名を含む Error を投げて終了コード 1 側に回す", () => {
    const resolve = (s) => { if (s === "oxlint") throw new Error("MODULE_NOT_FOUND"); return "/resolved"; };
    assert.throws(() => runChecks(createDeps({ resolve })), /道具を解決できません: oxlint/);
  });
  it("biome の起動が失敗したら throw し、scan へ進まない", () => {
    let scanned = false;
    const deps = createDeps({ runBiome: () => ({ status: 1, stderr: "boom" }), runScan: () => ((scanned = true), okScan()) });
    assert.throws(() => runChecks(deps), /biome を起動できません（終了コード 1）/);
    assert.equal(scanned, false);
  });

  it("失敗理由が無ければ 0 を返し、成功メッセージを出す", () => {
    const messages = [];
    assert.equal(runChecks(createDeps({ logSuccess: (m) => messages.push(m) })), 0);
    assert.match(messages[0], /一致します/);
  });

  it("対象ファイルが 0 件の report では、失敗として 1 を返す", () => {
    const failures = [];
    const deps = createDeps({
      runScan: () => ({
        stdout: JSON.stringify({ ...okReport, coverage: { supportedFiles: 0 } }),
        status: 0,
      }),
      logFailure: (m) => failures.push(m),
    });
    assert.equal(runChecks(deps), 1);
    assert.match(failures[0], /対象ファイルが 0 件/);
  });
});

describe("checkReport", () => {
  const finding = createFinding();
  const other = createFinding({ file: "scripts/index.py" });
  const lintFinding = createFinding({ engine: "lint", rule: "lint/example-rule", file: "scripts/lint_target.py", message: "Example lint message" });
  const createList = () => ({
    engines: ["lint", "code-quality"],
    missingToolsAllowed: {},
    accepted: [{ reason: "理由", findings: [finding, other] }, { reason: "理由", findings: [lintFinding] }],
  });
  const engines = {
    lint: { issues: 1, skipped: false },
    "code-quality": { issues: 2, skipped: false },
  };
  const coverage = { supportedFiles: 3 };
  const all = [finding, other, lintFinding].map(diagnosticOf);
  const present = () => false;

  it("エンジンが動き、指摘が一覧と一致すれば通る", () => {
    assert.deepEqual(checkReport(createList(), { engines, diagnostics: all, coverage }, present), []);
  });

  it("対象ファイルが 0 件なら、指摘が一致していても落ちる", () => {
    const failures = checkReport(
      createList(),
      { engines, diagnostics: all, coverage: { supportedFiles: 0 } },
      present,
    );
    assert.equal(failures.length, 1);
    assert.match(failures[0], /対象ファイルが 0 件/);
  });

  it("一覧に無い指摘があれば、その指摘を挙げて落ちる", () => {
    const failures = checkReport(createList(), {
      engines,
      diagnostics: [...all, createDiagnostic({ rule: "security/eval" })],
      coverage,
    }, present);
    assert.equal(failures.length, 1);
    assert.match(failures[0], /security\/eval/);
  });

  it("ある指摘だけが出なくなったら、一覧から消すよう求めて落ちる", () => {
    const failures = checkReport(createList(), {
      engines,
      diagnostics: [finding, lintFinding].map(diagnosticOf),
      coverage,
    }, present);
    assert.equal(failures.length, 1);
    assert.match(failures[0], /受け入れ一覧から消してください/);
    assert.match(failures[0], new RegExp(other.file.replace(/[.]/g, "\\.")));
  });

  it("エンジン 1 つ分の指摘がすべて出なくなったら、一覧から消せとは言わず、エンジンの疑いとして落ちる", () => {
    const failures = checkReport(createList(), {
      engines: { ...engines, lint: { issues: 0, skipped: false } },
      diagnostics: [finding, other].map(diagnosticOf),
      coverage,
    }, present);
    const joined = failures.join("\n");
    assert.match(joined, /lint: 一覧にある指摘 1 件がすべて出なくなりました/);
    assert.match(joined, /一覧から指摘を消さずに/);
    assert.doesNotMatch(joined, /受け入れ一覧から消してください/);
  });

  it("エンジンが外されたときは、そのエンジンの分を一覧から消せとは言わない", () => {
    const failures = checkReport(createList(), {
      engines: { "code-quality": engines["code-quality"] },
      diagnostics: [finding, other].map(diagnosticOf),
      coverage,
    }, present);
    const joined = failures.join("\n");
    assert.match(joined, /lint: 動いていません/);
    assert.match(joined, /lint: 一覧にある指摘 1 件がすべて出なくなりました/);
  });
});

describe("受け入れ一覧の形", () => {
  const listPath =
    process.env.AISLOP_CHECK_ACCEPTED ??
    path.join(here, "fixtures", "aislop-accepted.json");
  const list = JSON.parse(readFileSync(listPath, "utf8"));

  it("見るエンジンを挙げ、欠けてよい道具にはそれぞれ理由がある", () => {
    assert.ok(Array.isArray(list.engines) && list.engines.length > 0);
    for (const reason of Object.values(list.missingToolsAllowed ?? {})) {
      assert.match(reason, /\S/);
    }
  });

  it("どの群にも理由と1件以上の指摘があり、指摘は engine・rule・file・message を持つ", () => {
    for (const group of list.accepted) {
      assert.match(group.reason, /\S/);
      assert.ok(group.findings.length > 0);
      for (const finding of group.findings) {
        assert.ok(list.engines.includes(finding.engine));
        assert.deepEqual(Object.keys(finding).sort(), [
          "engine",
          "file",
          "message",
          "rule",
        ]);
      }
    }
  });
});

describe("実際の aislop との照合", () => {
  // TOOL_SPECIFIERS で確かめない指定子と、その理由。
  const notChecked = {
    "expo-doctor/package.json": "Expo のプロジェクトでだけ使う",
    "typescript/lib/tsc.js": "lint.typecheck が既定の false のままなら使わない",
  };
  const hasAislop = existsSync(config.aislopCli);

  it("aislop の dist が自分の場所から resolve する道具は、TOOL_SPECIFIERS と確かめない一覧で尽きる", { skip: !hasAislop }, () => {
    const source = readFileSync(config.aislopCli, "utf8");
    const specifiers = new Set(
      [...source.matchAll(/[\w$]*[Rr]equire[\w$]*\.resolve\((["'`])([^"'`]+)\1\)/g)].map(
        (match) => match[2],
      ),
    );
    assert.deepEqual(
      [...specifiers].sort(),
      [...Object.values(TOOL_SPECIFIERS), ...Object.keys(notChecked)].sort(),
    );
  });

  it("AISLOP_ENV を渡すと、CI=true の既定の設定でも利用統計を組み立てない", { skip: !hasAislop }, () => {
    const home = mkdtempSync(path.join(tmpdir(), "aislop-home-"));
    const run = (extra) =>
      spawnSync(process.execPath, [config.aislopCli, "rules"], {
        cwd: home,
        encoding: "utf8",
        env: {
          ...process.env,
          HOME: home,
          CI: "true",
          AISLOP_NO_TELEMETRY: "",
          AISLOP_NO_UPDATE_NOTIFIER: "",
          DO_NOT_TRACK: "",
          AISLOP_TELEMETRY_DEBUG: "1",
          AISLOP_TELEMETRY_DRY_RUN: "1",
          // DRY_RUN が効かなくなっても外へ出ないよう、送信先をつながらない手元の口にする
          AISLOP_POSTHOG_HOST: "http://127.0.0.1:9",
          ...extra,
        },
      }).stderr;
    try {
      assert.match(run({}), /\[telemetry\]/);
      assert.doesNotMatch(run(AISLOP_ENV), /\[telemetry\]/);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});
