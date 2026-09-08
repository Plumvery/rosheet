#!/usr/bin/env node

const { existsSync, writeFileSync, mkdirSync, readdirSync, readFileSync } = require("fs");
const path = require("path");

const { loadConfig, loadEnv, CONFIG_FILE } = require("../src/config");
const { createClient } = require("../src/opencloud");
const { normalizeSchema } = require("../src/schema");
const { normalizeDataset, orderDataset } = require("../src/rows");
const { sheetToCsv, csvToSheet } = require("../src/csv");
const generate = require("../src/generate");
const session = require("../src/session");
const store = require("../src/store");
const { writePlugin, DEFAULT_PLUGIN_FILE } = require("../src/studio-plugin");
const { writeRuntime } = require("../src/runtime");
const lock = require("../src/lock");

const HELP = `
rosheet - Roblox master data: define the schema in code, edit it in Studio, bake it into the place

Usage:
  rosheet init              Write ${CONFIG_FILE} into this project
  rosheet plugin            Write the Studio plugin into the local Plugins folder (install it once)
  rosheet runtime           Copy the runtime modules (defineSchema / bind) into this project
  rosheet update            Move the pin in ${lock.LOCK_FILE} and write the generated modules
  rosheet pull              Write the generated modules from the pin (or from the DataStore head)
  rosheet check             Fail if the generated modules do not match the pin (for CI)
  rosheet status            Compare the pin with the DataStore head
  rosheet tag [<name>]      List the tags, or name a commit so it can be pinned
  rosheet log               Show the Apply history
  rosheet revert <seq>      Push a new commit that restores the values of commit <seq>
  rosheet export            Write the current values as CSV
  rosheet import            Read CSV back in and Apply it as a new commit
  rosheet schema            Show the schema the plugin published
  rosheet help              Show this message

Options:
  --csv <dir>          CSV directory for export / import (default: rosheet-csv)
  --out, -o <path>     Output path for 'plugin' (default: the Studio local Plugins folder)
                       and for 'runtime' (default: a 'rosheet' folder next to output.dir)
  --save <file>        Write the schema to a file ('schema')
  --note <text>        Note attached to the commit ('import' / 'revert') or to the tag ('tag')
  --limit <n>          How many entries to show ('log', default 20)
  --tag <name>         Pin the commit this tag points at ('update')
  --seq <n>            Pin ('update') or tag ('tag') this commit instead of the head
  --head               Pin the current head ('update', the default)
  --force              Move a tag that already exists ('tag')
  --local              Work on ${lock.LOCK_FILE} without touching the DataStore ('import' / 'export')

Environment:
  ROSHEET_API_KEY      Open Cloud API key. Needs universe-datastores.objects:read,
                       plus :update for 'import', 'revert' and 'tag'. Read from .env if present.

Once ${lock.LOCK_FILE} exists, 'pull' / 'check' / 'import --local' / 'export --local' read the
values out of it and need no API key. 'update' is the only step that talks to the DataStore,
so what ships only moves when the pin moves — which is a diff, and therefore a review.

The plugin carries no project settings: it reads the schema, the DataStore name and the
rocas asset list from the place itself, so 'rosheet plugin' is a one-off.
`;

function flag(argv, name, fallback) {
	const index = argv.indexOf(name);
	return index === -1 || argv[index + 1] === undefined ? fallback : argv[index + 1];
}

function has(argv, name) {
	return argv.includes(name);
}

function clientFor(config) {
	// scope はプラグインが GetDataStore(name, scope) で使う。CLI が捨てると、両者が別の
	// キースペースを見て「プラグインでは編集できているのに pull が何も見つけない」になる
	return createClient({
		universe: config.project.universe,
		datastore: config.project.datastore,
		scope: config.project.scope,
	});
}

function seqFlag(argv, name) {
	const raw = flag(argv, name, null);
	if (raw === null) return null;
	const seq = Number(raw);
	if (!Number.isInteger(seq) || seq < 1) throw new Error(`${name} takes a commit number: ${raw}`);
	return seq;
}

function reportWrite(result) {
	if (result.written.length === 0 && result.removed.length === 0) {
		console.log(`Generated files are up to date (${result.total} files): ${result.outDir}`);
		return;
	}
	for (const name of result.written) console.log(`  wrote    ${name}`);
	for (const name of result.removed) console.log(`  removed  ${name}`);
	console.log(`${result.outDir}`);
}

async function cmdInit(cwd) {
	const target = path.join(cwd, CONFIG_FILE);
	if (existsSync(target)) throw new Error(`${CONFIG_FILE} already exists: ${target}`);
	writeFileSync(target, readFileSync(path.join(__dirname, "..", "rosheet.toml.example"), "utf8"), "utf8");
	console.log(`Wrote ${CONFIG_FILE}. Fill in project.universe and output.dir, then run 'rosheet plugin'`);
}

/** pin があればそれを焼く。無ければ今までどおり head を焼く（lock を作るまで挙動は変わらない） */
async function pinnedOrHead(config, cwd) {
	const opened = lock.openLock(cwd);
	if (opened !== null) return { ...opened, source: lock.sourceLabel(opened.lock), offline: true };

	const current = await session.readCurrent(clientFor(config));
	return { ...current, source: `commit #${current.head.seq}`, offline: false };
}

async function cmdPull(config, argv, cwd) {
	const at = await pinnedOrHead(config, cwd);
	const when = at.offline || at.commit.at === null ? "" : ` (${at.commit.at} by ${at.commit.by})`;
	console.log(`${at.source}${when}`);
	reportWrite(generate.write(at.schema, at.dataset, config, cwd, { source: at.source }));

	const csvDir = flag(argv, "--csv", null);
	if (csvDir !== null) writeCsv(at, path.resolve(cwd, csvDir));
}

async function cmdCheck(config, cwd) {
	const at = await pinnedOrHead(config, cwd);
	const problems = generate.check(at.schema, at.dataset, config, cwd, { source: at.source });
	if (problems.length === 0) {
		console.log(`Generated files match ${at.source}`);
		return;
	}
	for (const problem of problems) console.error(`  ${problem}`);
	throw new Error(`Generated files do not match ${at.source}. Run 'rosheet pull' and commit the result`);
}

/** pin を動かす唯一のコマンド。ここだけが DataStore を読み、結果を lock に固めて生成まで通す */
async function cmdUpdate(config, argv, cwd) {
	const client = clientFor(config);

	const tagName = flag(argv, "--tag", null);
	const wanted = seqFlag(argv, "--seq");
	if (tagName !== null && wanted !== null) throw new Error("Pass --tag or --seq, not both");

	let seq;
	let tag = null;
	if (tagName !== null) {
		const found = store.findTag(await session.readTags(client), tagName);
		if (found === undefined) throw new Error(`No such tag: ${tagName} (rosheet tag)`);
		seq = found.seq;
		tag = found.name;
	} else if (wanted !== null) {
		seq = wanted;
	} else {
		seq = (await session.readHead(client)).seq;
	}

	if (tag === null) {
		// その commit に名前が付いていれば拾う。生成物のヘッダと lock に出る出所が読みやすくなる
		const named = (await session.readTags(client)).entries.find((entry) => entry.seq === seq);
		if (named !== undefined) tag = named.name;
	}

	const at = await session.readAt(client, seq);
	const next = lock.buildLock({ schema: at.schema, dataset: at.dataset, commit: at.commit, tag });
	lock.writeLock(cwd, next);

	const source = lock.sourceLabel(next);
	console.log(`Pinned ${source} in ${lock.LOCK_FILE}`);
	// スキーマだけ publish されていて、まだ誰も Apply していない DataStore。値はスキーマの
	// 既定のままなので、そう書かないと「pull したのに空」に見える
	if (seq === 0) console.log("Nothing has been applied yet, so the pinned values are the schema defaults");
	reportWrite(generate.write(at.schema, at.dataset, config, cwd, { source }));
}

async function cmdStatus(config, cwd) {
	const { lock: pinned, schema, dataset } = lock.loadLock(cwd);
	const client = clientFor(config);
	const head = await session.readHead(client);

	const ahead = head.seq - pinned.seq;
	const distance =
		ahead > 0 ? `${ahead} commit${ahead === 1 ? "" : "s"} ahead of the pin` : ahead === 0 ? "same as the pin" : "behind the pin";
	console.log(`pinned  ${lock.sourceLabel(pinned)}${pinned.note === "" ? "" : `  — ${pinned.note}`}`);
	console.log(`head    #${head.seq}  (${distance})`);

	// pin が指す commit を引き直して、lock を手で動かしていないかを見る。ここが「PR で値を
	// 1 個だけ直した」を検出する唯一の場所で、それ自体は異常ではないので落とさずに並べる
	if (pinned.seq > 0) {
		const at = await session.readAt(client, pinned.seq);
		for (const name of lock.modifiedSheets(schema, dataset, at.dataset))
			console.log(`  edited in ${lock.LOCK_FILE}, not in the DataStore: ${name}`);
	}

	const problems = generate.check(schema, dataset, config, cwd, { source: lock.sourceLabel(pinned) });
	if (problems.length === 0) {
		console.log("Generated files match the pin");
		return;
	}
	for (const problem of problems) console.log(`  ${problem}`);
	console.log("Run 'rosheet pull' and commit the result");
}

async function cmdTag(config, argv, cwd) {
	const client = clientFor(config);
	const name = argv[3] !== undefined && !argv[3].startsWith("-") ? argv[3] : null;
	const tags = await session.readTags(client);

	if (name === null) {
		if ((tags.entries ?? []).length === 0) {
			console.log("No tags yet. 'rosheet tag <name>' names the current head");
			return;
		}
		for (const entry of tags.entries)
			console.log(`${entry.name}  ->  #${entry.seq}  ${entry.at ?? ""}${entry.note === "" ? "" : `  — ${entry.note}`}`);
		return;
	}

	store.checkTagName(name);
	const seq = seqFlag(argv, "--seq") ?? (await session.readHead(client)).seq;
	if (seq < 1) throw new Error("There is no commit to tag yet. Apply once from the Studio plugin");
	// 実在しない commit に名前を付けると、update がそこで初めて落ちる。ここで確かめる
	await session.readCommit(client, seq);

	const entry = { name, seq, at: new Date().toISOString(), by: "rosheet-cli", note: flag(argv, "--note", "") };
	await session.writeTags(client, store.putTag(tags, entry, { force: has(argv, "--force") }));
	console.log(`tag ${name} -> #${seq}. Run 'rosheet update --tag ${name}' to ship it`);
}

async function cmdLog(config, argv) {
	const log = await session.readLog(clientFor(config));
	const limit = Number(flag(argv, "--limit", "20"));
	if (log.entries.length === 0) {
		console.log("No Apply history yet");
		return;
	}
	for (const entry of log.entries.slice(0, limit)) {
		const revert = entry.revertOf === null || entry.revertOf === undefined ? "" : ` (revert of #${entry.revertOf})`;
		console.log(`#${entry.seq}  ${entry.at}  ${entry.by}${revert}`);
		console.log(`      ${entry.changed.join(", ")}${entry.note === "" ? "" : `  — ${entry.note}`}`);
	}
}

async function cmdRevert(config, argv, cwd) {
	const target = Number(argv[3]);
	if (!Number.isInteger(target) || target < 1) throw new Error("Pass the commit to restore: rosheet revert <seq>");

	const client = clientFor(config);
	const current = await session.readCurrent(client);
	const result = await session.revert(client, current, target, {
		at: new Date().toISOString(),
		by: "rosheet-cli",
		note: flag(argv, "--note", `revert to #${target}`),
	});
	console.log(`Pushed commit #${result.commit.seq} (restored the values of #${target})`);
	await regenerateAfterCommit(config, cwd, client);
}

/** commit を積んだあとの生成。pin があるときは焼き直さない —— 焼き直すと、出荷値を動かすのに
 * lock の diff が要る、という pin の目的そのものが消える */
async function regenerateAfterCommit(config, cwd, client) {
	const pinned = lock.readLock(cwd);
	if (pinned !== null) {
		console.log(`The pin still points at ${lock.sourceLabel(pinned)}. Run 'rosheet update' to ship this commit`);
		return;
	}
	const after = await session.readCurrent(client);
	reportWrite(generate.write(after.schema, after.dataset, config, cwd, { source: `commit #${after.head.seq}` }));
}

function writeCsv(current, dir) {
	mkdirSync(dir, { recursive: true });
	for (const sheet of current.schema.sheets)
		writeFileSync(path.join(dir, `${sheet.name}.csv`), sheetToCsv(sheet, current.dataset[sheet.name]), "utf8");
	console.log(`Wrote CSV: ${dir} (${current.schema.sheets.length} sheets)`);
}

async function cmdExport(config, argv, cwd) {
	const from = has(argv, "--local") ? lock.loadLock(cwd) : await session.readCurrent(clientFor(config));
	writeCsv(from, path.resolve(cwd, flag(argv, "--csv", "rosheet-csv")));
}

/** CSV の 1 ディレクトリを、現在のデータセットへ重ねる。CSV が無いシートは現在値のまま
 * （全シート分の CSV を揃えないと取り込めない、では使いにくい） */
function overlayCsv(schema, dataset, dir) {
	if (!existsSync(dir)) throw new Error(`No such CSV directory: ${dir}`);
	const present = new Set(readdirSync(dir).filter((name) => name.endsWith(".csv")));

	const next = {};
	for (const sheet of schema.sheets) {
		const file = `${sheet.name}.csv`;
		next[sheet.name] = present.has(file) ? csvToSheet(sheet, readFileSync(path.join(dir, file), "utf8")) : dataset[sheet.name];
	}
	return next;
}

async function cmdImport(config, argv, cwd) {
	const dir = path.resolve(cwd, flag(argv, "--csv", "rosheet-csv"));
	if (has(argv, "--local")) return importLocal(config, argv, cwd, dir);

	const client = clientFor(config);
	const current = await session.readCurrent(client);
	const next = overlayCsv(current.schema, current.dataset, dir);

	const result = await session.commitDataset(client, current, next, {
		at: new Date().toISOString(),
		by: "rosheet-cli",
		note: flag(argv, "--note", `import from ${path.basename(dir)}`),
	});
	if (result.changed.length === 0) {
		console.log("The CSV matches the current values, so no commit was pushed");
		return;
	}
	console.log(`Pushed commit #${result.commit.seq}: ${result.changed.join(", ")}`);
	await regenerateAfterCommit(config, cwd, client);
}

/** DataStore を通さない取り込み。lock の値を CSV で置き換えて焼き直すだけなので、キーが要らない。
 * ブランチの中だけで値を試す・キーを持たない人が値を直す・空の DataStore を待たずに初期値を
 * 入れる、がこれで閉じる（DataStore へ戻すのは Studio から Apply する） */
function importLocal(config, argv, cwd, dir) {
	const { lock: pinned, schema, dataset } = lock.loadLock(cwd);
	const next = normalizeDataset(schema, overlayCsv(schema, dataset, dir));

	const changed = lock.modifiedSheets(schema, dataset, next);
	if (changed.length === 0) {
		console.log(`The CSV matches ${lock.LOCK_FILE}, so nothing changed`);
		return;
	}

	lock.writeLock(cwd, { ...pinned, sheets: orderDataset(schema, next) });
	console.log(`Updated ${lock.LOCK_FILE}: ${changed.join(", ")}`);
	reportWrite(generate.write(schema, next, config, cwd, { source: lock.sourceLabel(pinned) }));
}

async function cmdSchema(config, argv, cwd) {
	const schema = await session.readSchema(clientFor(config));
	const save = flag(argv, "--save", null);
	if (save !== null) {
		const target = path.resolve(cwd, save);
		mkdirSync(path.dirname(target), { recursive: true });
		writeFileSync(target, `${JSON.stringify(schema, null, "\t")}\n`, "utf8");
		console.log(`Wrote the schema: ${target}`);
		return;
	}
	for (const sheet of schema.sheets)
		console.log(`${sheet.name}  (${sheet.kind}${sheet.key === null ? "" : `, key=${sheet.key}`})  ${sheet.columns.length} columns`);
}

async function cmdPlugin(argv, cwd) {
	const result = writePlugin({ output: flag(argv, "--out", flag(argv, "-o", null)), cwd });
	console.log(`Wrote the plugin: ${result.path}`);
	if (result.intoStudio) console.log("Restart Studio, or reload its plugins. Installing it once is enough.");
}

async function cmdRuntime(config, argv, cwd) {
	const result = writeRuntime(config, { output: flag(argv, "--out", flag(argv, "-o", null)), cwd });
	if (result.written.length === 0) {
		console.log(`The runtime is up to date (${result.total} files): ${result.outDir}`);
		return;
	}
	for (const name of result.written) console.log(`  wrote    ${name}`);
	console.log(result.outDir);
	// 複製なので、上げたぶんは自動では追いつかない。それがこのコマンドの唯一の弱点なので先に言う
	console.log("Run this again after upgrading rosheet, and commit the result.");
	// Studio の require は戻り値をインスタンス単位で恒久的にキャッシュする。Rojo が同期しても
	// 古いランタイムが評価され続けるので、新しい宣言はその 1 セッションのあいだ効かない。
	// プラグインは見つけて読み取り専用になるが、先に言っておく方が短い
	console.log("If Studio is open, restart it: it keeps evaluating the runtime it loaded at startup.");
}

async function main() {
	const argv = process.argv;
	const command = argv[2];
	const cwd = process.cwd();

	if (command === undefined || command === "help" || has(argv, "--help") || has(argv, "-h")) {
		console.log(HELP.trim());
		return;
	}

	loadEnv(cwd);
	if (command === "init") return cmdInit(cwd);
	// plugin は rosheet.toml を読まない。プラグインには何も焼かないので設定が要らない
	if (command === "plugin") return cmdPlugin(argv, cwd);

	const config = loadConfig(cwd);
	switch (command) {
		case "runtime":
			return cmdRuntime(config, argv, cwd);
		case "update":
			return cmdUpdate(config, argv, cwd);
		case "pull":
			return cmdPull(config, argv, cwd);
		case "check":
			return cmdCheck(config, cwd);
		case "status":
			return cmdStatus(config, cwd);
		case "tag":
			return cmdTag(config, argv, cwd);
		case "log":
			return cmdLog(config, argv);
		case "revert":
			return cmdRevert(config, argv, cwd);
		case "export":
			return cmdExport(config, argv, cwd);
		case "import":
			return cmdImport(config, argv, cwd);
		case "schema":
			return cmdSchema(config, argv, cwd);
		default:
			throw new Error(`Unknown command: ${command} (rosheet help)`);
	}
}

main().catch((error) => {
	console.error(`rosheet: ${error.message}`);
	process.exit(1);
});
