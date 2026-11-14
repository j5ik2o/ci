/**
 * aislop の scan が、呼び出し側リポジトリの受け入れ一覧（aislop-accepted.json）と
 * 食い違えば落ちる検査の正本。j5ik2o/ci の aislop/ に1つだけ置き、各リポジトリは
 * 版を固定して参照する（参照の仕組みは aislop/README.md）。
 *
 * 使い方:
 *   node check-aislop.mjs --root <リポジトリのルート> --accepted <受け入れ一覧のパス>
 *   --root を省略すると環境変数 AISLOP_CHECK_ROOT、無ければカレントディレクトリ。
 *   --accepted を省略すると <root>/scripts/aislop-accepted.json。
 *   aislop 本体は <root>/node_modules/aislop/dist/cli.js を使う（版は呼び出し側が
 *   devDependencies で固定する。この正本が相手にするのは aislop 0.20.1）。
 *
 * 落ちるのは次のとき。
 * - 一覧に無い warn 以上の指摘がある。一覧にある指摘が出なくなった。
 * - 空振りを防ぐ3つの確認のどれかに触れた（全プロジェクト共通の必須仕様、
 *   2026-11-14 に横断で決定）。
 *   1. スキャンの対象ファイルが 0件、または対象ファイル数を確認できない。
 *      何も見ていない scan を、一覧と一致したとは見なさない。
 *   2. エンジンが止まった（skipped）ときは、検査側が道具の未導入を自分で確かめ、
 *      欠けた道具がすべて「未導入を確認でき、かつ欠落が許可された道具」の場合だけ
 *      通す。それ以外は落ちる。aislop 0.20.1 はエンジンの故障を専用の記録で出さず
 *      skipped で表すため、道具の欠落による停止と故障による停止は、scan の結果
 *      だけでは区別できない。だから検査側の実地の確認が要る。
 *   3. 一覧の engines に挙げたエンジンの記録が、scan の結果に無い。
 * - 許可していない道具が欠けている。一覧にある、あるエンジンの指摘がすべて
 *   出なくなった（道具が動いていない疑いとして扱う。指摘を消してよいのは、
 *   そのエンジンが別の指摘を出せることを確かめてから）。
 *
 * 指摘がエンジン 1 つ分すべて出なくなったときの判定は指摘の数によるので、
 * 受け入れた指摘が 0 件の道具（format の biome、code-quality の knip）が止まっても
 * 分からない。そこで scan の前に、aislop の場所から oxlint・biome・knip を解決
 * できるかを見て、できなければ道具の名前を挙げて落ちる。oxlint が解決できない
 * とき、aislop は lint を skipped にも missingTools にもせず、指摘 0 件で返すため
 * である。biome は package.json を解決できても、プラットフォームごとの本体
 * （@biomejs/cli-<platform>、optional dependencies）が無いと動かないので、
 * `biome --version` も走らせる。解決でき、起動もできるのに道具が黙って止まる
 * 場合は塞げない。
 * TOOL_SPECIFIERS は aislop の dist が resolve に渡す指定子の写しで、テストが
 * 実際の dist と照らす。
 *
 * aislop 自身の baseline（`aislop baseline write`）は `.aislop/` に置く決まりで、
 * 項目ごとに理由も書けないので、一覧はリポジトリごとに自前で持つ。
 * 指摘はエンジン・規則・ファイル・文言で照合し、行番号は見ない（前後の行を
 * 足しても一覧を直さずに済むように）。同じエンジン・規則・ファイル・文言の
 * 指摘が複数あるときは、一覧にも同じ数だけ並べる。
 *
 * aislop は既定で利用統計を外（eu.i.posthog.com）へ送り、設定の telemetry.enabled
 * が既定の true のままだと CI=true でも止まらない。外への送信は承認が要るので、
 * aislop を起動するときは AISLOP_ENV で止める。
 *
 * scan には内側の制限時間（既定600秒、AISLOP_CHECK_SCAN_TIMEOUT_MS で変更可）を
 * 設ける。呼び出し側の外側の期限（CI のステップや検証スクリプトのタイムアウト）
 * より先に内側が終わる形にし、外側が起動役ごと終了しても scan のプロセスが
 * 残り続けないようにするためである（issue #20）。起動役（bootstrap）側の
 * 子プロセスにも制限時間（既定660秒）があり、内側から順に 600秒・660秒・
 * 呼び出し側の期限、の順で発火する。
 * 制限時間の超過時は、直接の子だけでなくプロセスツリーごと終了する。scan は
 * 専用プロセスグループで起動し、超過時はグループ全体へ終了信号を送る
 * （猶予の後に強制終了）。この検査自身が SIGTERM や SIGINT を受けたときも、
 * scan のグループを終了してから死ぬ。SIGKILL は受け取れないため、その場合は
 * scan が残る余地がある（起動役側も同じ構造で、検査のグループごと終了する）。
 */
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const GATED_SEVERITIES = new Set(["error", "warning"]);
const SCHEMA_VERSION = "1";
/** aislop が自分の場所から解決する道具と、aislop 自身が resolve に渡す指定子。 */
export const TOOL_SPECIFIERS = {
  oxlint: "oxlint",
  "@biomejs/biome": "@biomejs/biome/package.json",
  knip: "knip",
};
/** Node の道具ではなく、実行ファイルの有無で未導入を確かめる道具。 */
export const EXTERNAL_TOOL_COMMANDS = {
  ruff: "ruff",
};

/** aislop の利用統計と更新の確認（npm registry への問い合わせ）を止める。 */
export const AISLOP_ENV = {
  AISLOP_NO_TELEMETRY: "1",
  AISLOP_NO_UPDATE_NOTIFIER: "1",
};

/**
 * scan の制限時間の既定（ミリ秒）。呼び出し側の外側の期限より先に内側が
 * 終わるように置く内側の期限で、起動役の子プロセスの制限時間（660秒）と
 * 呼び出し側の期限（例：690秒）の内側に収まる順序にする。
 */
export const SCAN_TIMEOUT_MS = 600_000;
/** 道具の版確認（biome --version、ruff --version）の制限時間（ミリ秒）。 */
const PROBE_TIMEOUT_MS = 30_000;
/** プロセスツリーへ終了信号を送ってから、強制終了まで待つ猶予（ミリ秒）。 */
const TREE_KILL_GRACE_MS = 3_000;

/** ミリ秒指定の環境変数を読む。正の整数でなければ既定を返す。 */
function timeoutFromEnv(value, fallback) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

/**
 * 起動引数と環境変数から、ルートと受け入れ一覧と aislop 本体の場所を決める。
 * 既定: ルートは AISLOP_CHECK_ROOT、無ければカレントディレクトリ。
 * 受け入れ一覧は AISLOP_CHECK_ACCEPTED、無ければ <root>/scripts/aislop-accepted.json。
 * aislop 本体は AISLOP_CHECK_CLI、無ければ <root>/node_modules/aislop/dist/cli.js。
 */
export function resolveConfig(argv = [], env = {}, cwd = process.cwd()) {
  const args = new Map();
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i].startsWith("--")) {
      args.set(argv[i], argv[i + 1]);
      i += 1;
    }
  }
  const root = path.resolve(
    args.get("--root") ?? env.AISLOP_CHECK_ROOT ?? cwd,
  );
  const acceptedPath = path.resolve(
    root,
    args.get("--accepted") ??
      env.AISLOP_CHECK_ACCEPTED ??
      path.join("scripts", "aislop-accepted.json"),
  );
  const aislopCli = path.resolve(
    root,
    args.get("--aislop-cli") ??
      env.AISLOP_CHECK_CLI ??
      path.join("node_modules", "aislop", "dist", "cli.js"),
  );
  const scanTimeoutMs = timeoutFromEnv(
    env.AISLOP_CHECK_SCAN_TIMEOUT_MS,
    SCAN_TIMEOUT_MS,
  );
  return { root, acceptedPath, aislopCli, scanTimeoutMs };
}

const keyOf = ({ engine, rule, file, message }) =>
  `${engine}\0${rule}\0${file}\0${message}`;

/**
 * 一覧（accepted の findings）と scan の diagnostics を突き合わせる。
 * unlisted は一覧に無い warn 以上の指摘、resolved は一覧にあるのに出なくなった指摘。
 */
export function compareFindings(accepted, diagnostics) {
  const remaining = new Map();
  for (const finding of accepted.flatMap((group) => group.findings)) {
    const key = keyOf(finding);
    remaining.set(key, [...(remaining.get(key) ?? []), finding]);
  }
  const unlisted = [];
  for (const diagnostic of diagnostics) {
    if (!GATED_SEVERITIES.has(diagnostic.severity)) continue;
    const finding = {
      engine: diagnostic.engine,
      rule: diagnostic.rule,
      file: diagnostic.filePath,
      message: diagnostic.message,
    };
    const listed = remaining.get(keyOf(finding));
    if (listed?.length) listed.pop();
    else unlisted.push({ ...finding, line: diagnostic.line });
  }
  return { unlisted, resolved: [...remaining.values()].flat() };
}

/** resolve で解決できない道具の名前を返す。 */
export function findUnresolvableTools(resolve) {
  return Object.entries(TOOL_SPECIFIERS)
    .filter(([, specifier]) => {
      try {
        resolve(specifier);
        return false;
      } catch {
        return true;
      }
    })
    .map(([name]) => name);
}

/**
 * scan の結果から対象ファイル数を返す。coverage.supportedFiles を優先し、
 * 無ければ summary.files を使う。どちらも数で無ければ null（確認できない）。
 */
export function scanFileCount(report) {
  const fromCoverage = report?.coverage?.supportedFiles;
  if (typeof fromCoverage === "number" && Number.isFinite(fromCoverage)) {
    return fromCoverage;
  }
  const fromSummary = report?.summary?.files;
  if (typeof fromSummary === "number" && Number.isFinite(fromSummary)) {
    return fromSummary;
  }
  return null;
}

/**
 * 空振りを防ぐ確認1: 対象ファイルが 0件、または確認できないなら、その文を返す。
 * 問題が無ければ null。
 */
export function checkCoverage(report) {
  const count = scanFileCount(report);
  if (count === null) {
    return "スキャンの対象ファイル数を確認できません（coverage.supportedFiles も summary.files もありません）。何も見ていない scan を通さないため、aislop の出力の形が変わっていないか確かめてください";
  }
  if (count === 0) {
    return "スキャンの対象ファイルが 0 件です。何も見ていない scan を、一覧と一致したとは見なしません。aislop の設定と対象の指定を確かめてください";
  }
  return null;
}

/**
 * 一覧の engines ごとに、動いていない疑いを調べる。問題ごとに { engine, reason } を返す。
 * probeTool は、道具の名前を受け取り、その道具が未導入であることを検査側が
 * 自分で確かめられた場合にだけ true を返す（空振りを防ぐ確認2の実地の確認）。
 * - エンジンの記録が結果に無い（確認3）。
 * - エンジンが skipped のときは、欠けた道具がすべて「未導入を確認でき、かつ
 *   欠落が許可された道具」であれば通し、それ以外は問題にする（確認2）。
 *   欠けた道具の記録が無い skipped は、未導入による停止か確かめられないので問題にする。
 * - 止まっていないエンジンでも、許可していない道具が欠けていれば問題にする。
 * - 一覧にあるそのエンジンの指摘がすべて resolved に入ったら、道具停止の疑いにする。
 */
export function checkEngines(list, reportEngines, resolved, probeTool) {
  const count = (findings, name) =>
    findings.filter((f) => f.engine === name).length;
  const acceptedFindings = list.accepted.flatMap((group) => group.findings);
  const problems = [];
  for (const name of list.engines) {
    const engine = reportEngines[name];
    const listed = count(acceptedFindings, name);
    if (!engine) {
      problems.push({
        engine: name,
        reason:
          "動いていません（.aislop/config.yml などで外されていないか確かめてください）",
      });
    } else if (engine.skipped) {
      const missing = engine.missingTools ?? [];
      if (missing.length === 0) {
        problems.push({
          engine: name,
          reason:
            "skipped になりました。欠けた道具の記録が無いため、道具の未導入による停止かどうかを確かめられません",
        });
      } else {
        for (const tool of missing) {
          if (!Object.hasOwn(list.missingToolsAllowed, tool)) {
            problems.push({
              engine: name,
              reason: `skipped になりました。欠けた道具 ${tool} は、欠落が許可されていません`,
            });
          } else if (!probeTool(tool)) {
            problems.push({
              engine: name,
              reason: `skipped になりました。欠けた道具 ${tool} の未導入を、検査側で確かめられませんでした（実際には導入されているか、確かめる方法が無い道具です）`,
            });
          }
        }
      }
    } else {
      for (const tool of engine.missingTools ?? []) {
        if (!Object.hasOwn(list.missingToolsAllowed, tool)) {
          problems.push({
            engine: name,
            reason: `道具 ${tool} が見つかりません（npm ci をやり直してください）`,
          });
        }
      }
    }
    if (listed > 0 && count(resolved, name) === listed) {
      problems.push({
        engine: name,
        reason: `一覧にある指摘 ${listed} 件がすべて出なくなりました。道具が動いていない疑いがあります（npm ci をやり直してください。やり直しても同じなら、本当に直ったのかもしれません。そのエンジンが別の指摘を出せることを確かめてから、一覧から消してください）`,
      });
    }
  }
  return problems;
}

/** scan の JSON が、このスクリプトの読める形かを見る。読めなければ理由を投げる。 */
export function assertReportShape(report) {
  const problems = [];
  if (report?.schemaVersion !== SCHEMA_VERSION) {
    problems.push(
      `schemaVersion が ${JSON.stringify(report?.schemaVersion)} です（このスクリプトが読めるのは ${SCHEMA_VERSION}）`,
    );
  }
  if (typeof report?.engines !== "object" || report.engines === null) {
    problems.push("engines がありません");
  }
  if (!Array.isArray(report?.diagnostics)) {
    problems.push("diagnostics が配列ではありません");
  }
  if (problems.length > 0) {
    throw new Error(
      [
        `aislop scan --json の形が、このスクリプトの想定と違います（aislop@${report?.cliVersion}）。aislop の版を上げたなら、正本（j5ik2o/ci の aislop/check-aislop.mjs）を新しい形に合わせてください。`,
        ...problems.map((line) => `  ${line}`),
      ].join("\n"),
    );
  }
}

/** 一覧と scan の JSON から、落ちる理由を文の配列で返す。空なら通る。 */
export function checkReport(list, report, probeTool) {
  const { unlisted, resolved } = compareFindings(
    list.accepted,
    report.diagnostics,
  );
  const failures = [];
  const coverageProblem = checkCoverage(report);
  if (coverageProblem !== null) {
    failures.push(
      `aislop のスキャンが対象を見ていない疑いがあります。${coverageProblem}。`,
    );
  }
  const engineProblems = checkEngines(list, report.engines, resolved, probeTool);
  const suspectEngines = new Set(engineProblems.map((p) => p.engine));
  if (engineProblems.length > 0) {
    failures.push(
      [
        `aislop のエンジンが動いていない疑いがあります（${engineProblems.length} 件）。動かないエンジンの指摘は出ないので、そのエンジンの分は一覧と照らせません。一覧から指摘を消さずに、エンジンが動くようにしてから実行し直してください。`,
        ...engineProblems.map((p) => `  ${p.engine}: ${p.reason}`),
      ].join("\n"),
    );
  }
  if (unlisted.length > 0) {
    failures.push(
      [
        `受け入れ一覧に無い warn 以上の指摘が ${unlisted.length} 件あります。`,
        ...unlisted.map(
          (f) => `  ${f.file}:${f.line}  ${f.engine}  ${f.rule}  ${f.message}`,
        ),
        "直すか、残す理由があるなら一覧の理由が合う群（無ければ新しい群）に engine・rule・file・message を足してください。",
        "aislop は作業ツリーをそのまま読むので、追跡していない手元のファイルの指摘も出ます。",
      ].join("\n"),
    );
  }
  const fixed = resolved.filter((f) => !suspectEngines.has(f.engine));
  if (fixed.length > 0) {
    failures.push(
      [
        `一覧にあるが出なくなった指摘が ${fixed.length} 件あります。直したのなら受け入れ一覧から消してください（群が空になったら群ごと消す）。`,
        ...fixed.map(
          (f) => `  ${f.file}  ${f.engine}  ${f.rule}  ${f.message}`,
        ),
      ].join("\n"),
    );
  }
  return failures;
}

/**
 * 子プロセスを専用プロセスグループで起動し、結果を spawnSync の結果と
 * 同じ形（error / stdout / stderr / status）で返す。制限時間を超えたら、
 * 直接の子だけでなくグループ全体へ終了信号を送り、猶予の後に強制終了
 * する（scan が起動した道具も同じグループにいる）。この検査自身が
 * SIGTERM や SIGINT を受けたときも、グループを終了してから同じ信号で
 * 死ぬ。Windows ではプロセスグループが無いため、直接の子だけを終了する。
 */
export function spawnScan(command, args, { cwd, env, timeoutMs, maxBuffer }) {
  return new Promise((resolvePromise) => {
    const useGroup = process.platform !== "win32";
    const child = spawn(command, args, { cwd, env, detached: useGroup });
    let stdout = "";
    let stderr = "";
    let failure = null;
    let settled = false;
    let killTimer = null;
    const killTree = (signal) => {
      if (useGroup && child.pid) {
        try {
          process.kill(-child.pid, signal);
          return;
        } catch {
          // グループへ送れなければ、直接の子だけでも終了する。
        }
      }
      try {
        child.kill(signal);
      } catch {
        // 終了済みなら何もしない。
      }
    };
    const onSigterm = () => forward("SIGTERM");
    const onSigint = () => forward("SIGINT");
    const forward = (signal) => {
      killTree("SIGKILL");
      process.removeListener("SIGTERM", onSigterm);
      process.removeListener("SIGINT", onSigint);
      process.kill(process.pid, signal);
    };
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      process.removeListener("SIGTERM", onSigterm);
      process.removeListener("SIGINT", onSigint);
      resolvePromise(result);
    };
    const timer = setTimeout(() => {
      failure = Object.assign(new Error(`spawn ${command} ETIMEDOUT`), {
        code: "ETIMEDOUT",
      });
      killTree("SIGTERM");
      killTimer = setTimeout(() => killTree("SIGKILL"), TREE_KILL_GRACE_MS);
    }, timeoutMs);
    process.on("SIGTERM", onSigterm);
    process.on("SIGINT", onSigint);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (!failure && stdout.length + stderr.length > maxBuffer) {
        failure = Object.assign(new Error("spawn output exceeded maxBuffer"), {
          code: "ENOBUFS",
        });
        killTree("SIGKILL");
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      finish({ error: failure ?? error, stdout, stderr, status: null });
    });
    child.on("close", (status) => {
      if (failure) {
        finish({ error: failure, stdout, stderr, status: null });
      } else {
        finish({ stdout, stderr, status });
      }
    });
  });
}

/**
 * 起動の結果を受け取り、report を返すか理由付きで投げる。
 * 起動をここで行わないのは、起動結果を差し替えて失敗の終端をテストできるようにするため。
 */
export function scan(result) {
  if (result.error) {
    if (result.error.code === "ETIMEDOUT") {
      throw new Error(
        "aislop の scan が制限時間を超えたため、失敗にします。scan が止まっている可能性があります。制限時間は AISLOP_CHECK_SCAN_TIMEOUT_MS で変更できます（既定は600秒です）。",
      );
    }
    throw new Error(`aislop を起動できませんでした: ${result.error.message}`);
  }
  let report;
  try {
    report = JSON.parse(result.stdout);
  } catch {
    throw new Error(
      `aislop scan --json の出力を読めませんでした（終了コード ${result.status}）。npm ci が済んでいるか確かめてください。\n${result.stderr}`,
    );
  }
  assertReportShape(report);
  return report;
}

/**
 * `spawnSync` の結果を受け取り、biome の起動が失敗していれば理由付きで投げる。
 * 起動をここで行わないのは、起動結果を差し替えて失敗の終端をテストできるようにするため。
 */
export function assertBiomeRuns(result) {
  if (result.error) {
    throw new Error(
      `biome を起動できません: ${result.error.message}。プラットフォームの本体（@biomejs/cli-${process.platform}-${process.arch} など）が入っていないかもしれません。動かない biome は指摘 0 件で返るので、scan の前に落とします。npm ci をやり直してください。`,
    );
  }
  if (result.status !== 0) {
    throw new Error(
      `biome を起動できません（終了コード ${result.status}）。プラットフォームの本体（@biomejs/cli-${process.platform}-${process.arch} など）が入っていないかもしれません。動かない biome は指摘 0 件で返るので、scan の前に落とします。npm ci をやり直してください。\n${result.stderr}`,
    );
  }
}

/**
 * 道具の未導入を、検査側が自分で確かめるための probe を作る。
 * Node の道具（TOOL_SPECIFIERS）は aislop の場所からの resolve の成否で見る。
 * 実行ファイルの道具（EXTERNAL_TOOL_COMMANDS）は `--version` の起動を試し、
 * ファイルが無い（ENOENT）ときだけ未導入と見なす。実行権限の不足（EACCES）
 * や、起動できたのに失敗する場合は、その道具が存在しないことの証明には
 * ならないので、未導入とは見なさない。
 * どちらの方法も無い道具は、未導入を確かめられないものとして false を返す。
 * 戻り値は「未導入を確認できた」ときだけ true。
 */
export function createProbeTool({ resolve, runVersion }) {
  return (tool) => {
    if (Object.hasOwn(TOOL_SPECIFIERS, tool)) {
      try {
        resolve(TOOL_SPECIFIERS[tool]);
        return false;
      } catch {
        return true;
      }
    }
    if (Object.hasOwn(EXTERNAL_TOOL_COMMANDS, tool)) {
      const result = runVersion(EXTERNAL_TOOL_COMMANDS[tool]);
      return result.error?.code === "ENOENT";
    }
    return false;
  };
}

/**
 * aislop 本体を起点にする require を作る。pnpm のように node_modules/aislop が
 * シンボリックリンクの構成では、リンクの場所を起点にすると aislop の依存先
 * （oxlint など、実体の隣に置かれる）へ届かないため、実パスへ直してから作る。
 */
export function createAislopRequire(cliPath) {
  return createRequire(realPath(cliPath));
}

/**
 * `main` の中身。一覧の読み込み・道具の resolve・biome と scan の起動・probe を
 * 依存として受け取り、成功なら 0、失敗理由があれば 1 を返す（投げる失敗は
 * そのまま呼び出し元へ伝える）。依存を引数にしているのは、resolve 失敗の
 * throw などの結線を実 I/O なしでテストできるようにするため。scan の起動は
 * 非同期（spawnScan）なので、この関数も非同期である。runScan が Promise で
 * ない結果を返しても、そのまま扱える。
 */
export async function runChecks({
  readList,
  resolve,
  runBiome,
  runScan,
  probeTool,
  acceptedLabel,
  logSuccess,
  logFailure,
}) {
  const list = readList();
  const unresolvable = findUnresolvableTools(resolve);
  if (unresolvable.length > 0) {
    throw new Error(
      `aislop の場所から道具を解決できません: ${unresolvable.join("、")}。解決できない道具は指摘 0 件で返ることがあるので、scan の前に落とします。npm ci をやり直してください。`,
    );
  }
  assertBiomeRuns(runBiome(resolve(TOOL_SPECIFIERS["@biomejs/biome"])));
  const report = scan(await runScan());
  const failures = checkReport(list, report, probeTool);
  if (failures.length === 0) {
    logSuccess(
      `aislop@${report.cliVersion} の warn 以上の指摘は、${acceptedLabel} と一致します。`,
    );
    return 0;
  }
  logFailure(
    [
      ...failures,
      `aislop@${report.cliVersion}（oxlint・biome・knip の版は、呼び出し側の package-lock.json で決まります）。`,
    ].join("\n\n"),
  );
  return 1;
}

async function main() {
  const config = resolveConfig(process.argv.slice(2), process.env);
  const requireFromAislop = createAislopRequire(config.aislopCli);
  const resolve = requireFromAislop.resolve;
  return runChecks({
    readList: () => JSON.parse(readFileSync(config.acceptedPath, "utf8")),
    resolve,
    runBiome: (biomePackageJson) =>
      spawnSync(
        process.execPath,
        [path.join(path.dirname(biomePackageJson), "bin", "biome"), "--version"],
        { encoding: "utf8", timeout: PROBE_TIMEOUT_MS },
      ),
    runScan: () =>
      spawnScan(process.execPath, [config.aislopCli, "scan", "--json"], {
        cwd: config.root,
        env: { ...process.env, ...AISLOP_ENV },
        maxBuffer: 64 * 1024 * 1024,
        timeoutMs: config.scanTimeoutMs,
      }),
    probeTool: createProbeTool({
      resolve,
      runVersion: (command) =>
        spawnSync(command, ["--version"], {
          encoding: "utf8",
          timeout: PROBE_TIMEOUT_MS,
        }),
    }),
    acceptedLabel: path.relative(config.root, config.acceptedPath),
    logSuccess: (message) => console.log(message),
    logFailure: (message) => console.error(message),
  });
}

if (
  process.argv[1] &&
  realPath(process.argv[1]) === realPath(fileURLToPath(import.meta.url))
) {
  try {
    process.exit(await main());
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}

/** 実パスで比べる。シンボリックリンク経由の実行でも entry guard を一致させる。 */
function realPath(target) {
  try {
    return realpathSync(target);
  } catch {
    return path.resolve(target);
  }
}
