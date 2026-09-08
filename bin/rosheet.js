#!/usr/bin/env node

const { existsSync, writeFileSync, mkdirSync, readdirSync, readFileSync } = require("fs");
const path = require("path");

const { loadConfig, loadEnv, CONFIG_FILE } = require("../src/config");
const { createClient } = require("../src/opencloud");
const { normalizeSchema } = require("../src/schema");
const { normalizeDataset } = require("../src/rows");
const { sheetToCsv, csvToSheet } = require("../src/csv");
const generate = require("../src/generate");
const session = require("../src/session");
const store = require("../src/store");
const { writePlugin, DEFAULT_PLUGIN_FILE } = require("../src/studio-plugin");

const HELP = `
rosheet - Roblox master data: define the schema in code, edit it in Studio, bake it into the place

Usage:
  rosheet init              Write ${CONFIG_FILE} into this project
  rosheet plugin            Generate the Studio plugin into the local Plugins folder
  rosheet pull              Read the current values from the DataStore and write the generated modules
  rosheet check             Fail if the generated modules do not match the current values (for CI)
  rosheet log               Show the Apply history
  rosheet revert <seq>      Push a new commit that restores the values of commit <seq>
  rosheet export            Write the current values as CSV
  rosheet import            Read CSV back in and Apply it as a new commit
  rosheet schema            Show the schema the plugin published
  rosheet help              Show this message

Options:
  --csv <dir>          CSV directory for export / import (default: rosheet-csv)
  --out, -o <path>     Output path for 'plugin' (default: the Studio local Plugins folder)
  --save <file>        Write the schema to a file ('schema')
  --note <text>        Note attached to the commit ('import' / 'revert')
  --limit <n>          How many entries to show ('log', default 20)

Environment:
  ROSHEET_API_KEY      Open Cloud API key. Needs universe-datastores.objects:read,
                       plus :update for 'import' and 'revert'. Read from .env if present.
`;

function flag(argv, name, fallback) {
	const index = argv.indexOf(name);
	return index === -1 || argv[index + 1] === undefined ? fallback : argv[index + 1];
}

function has(argv, name) {
	return argv.includes(name);
}

function clientFor(config) {
	return createClient({ universe: config.project.universe, datastore: config.project.datastore });
}

function reportWrite(result) {
	if (result.written.length === 0 && result.removed.length === 0) {
		console.log(`生成物は最新（${result.total} ファイル）: ${result.outDir}`);
		return;
	}
	for (const name of result.written) console.log(`  書いた  ${name}`);
	for (const name of result.removed) console.log(`  消した  ${name}`);
	console.log(`${result.outDir}`);
}

async function cmdInit(cwd) {
	const target = path.join(cwd, CONFIG_FILE);
	if (existsSync(target)) throw new Error(`${CONFIG_FILE} は既にある: ${target}`);
	writeFileSync(target, readFileSync(path.join(__dirname, "..", "rosheet.toml.example"), "utf8"), "utf8");
	console.log(`${CONFIG_FILE} を書いた。project.universe と output.dir を埋めてから 'rosheet plugin' を実行する`);
}

async function cmdPull(config, argv, cwd) {
	const current = await session.readCurrent(clientFor(config));
	console.log(`commit #${current.head.seq}${current.commit.at === null ? "" : ` (${current.commit.at} by ${current.commit.by})`}`);
	reportWrite(generate.write(current.schema, current.dataset, config, cwd));

	const csvDir = flag(argv, "--csv", null);
	if (csvDir !== null) writeCsv(current, path.resolve(cwd, csvDir));
}

async function cmdCheck(config, cwd) {
	const current = await session.readCurrent(clientFor(config));
	const problems = generate.check(current.schema, current.dataset, config, cwd);
	if (problems.length === 0) {
		console.log(`生成物は commit #${current.head.seq} と一致している`);
		return;
	}
	for (const problem of problems) console.error(`  ${problem}`);
	throw new Error(`生成物が commit #${current.head.seq} と違う。'rosheet pull' を実行してコミットする`);
}

async function cmdLog(config, argv) {
	const log = await session.readLog(clientFor(config));
	const limit = Number(flag(argv, "--limit", "20"));
	if (log.entries.length === 0) {
		console.log("Apply の履歴がまだ無い");
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
	if (!Number.isInteger(target) || target < 1) throw new Error("戻したい commit の番号を渡す: rosheet revert <seq>");

	const client = clientFor(config);
	const current = await session.readCurrent(client);
	const result = await session.revert(client, current, target, {
		at: new Date().toISOString(),
		by: "rosheet-cli",
		note: flag(argv, "--note", `revert to #${target}`),
	});
	console.log(`commit #${result.commit.seq} を積んだ（#${target} の値へ戻した）`);

	const after = await session.readCurrent(client);
	reportWrite(generate.write(after.schema, after.dataset, config, cwd));
}

function writeCsv(current, dir) {
	mkdirSync(dir, { recursive: true });
	for (const sheet of current.schema.sheets)
		writeFileSync(path.join(dir, `${sheet.name}.csv`), sheetToCsv(sheet, current.dataset[sheet.name]), "utf8");
	console.log(`CSV を書いた: ${dir}（${current.schema.sheets.length} シート）`);
}

async function cmdExport(config, argv, cwd) {
	const current = await session.readCurrent(clientFor(config));
	writeCsv(current, path.resolve(cwd, flag(argv, "--csv", "rosheet-csv")));
}

async function cmdImport(config, argv, cwd) {
	const dir = path.resolve(cwd, flag(argv, "--csv", "rosheet-csv"));
	if (!existsSync(dir)) throw new Error(`CSV のディレクトリが無い: ${dir}`);

	const client = clientFor(config);
	const current = await session.readCurrent(client);
	const present = new Set(readdirSync(dir).filter((name) => name.endsWith(".csv")));

	const next = {};
	for (const sheet of current.schema.sheets) {
		const file = `${sheet.name}.csv`;
		// CSV が無いシートは現在値のまま。全シート分の CSV を揃えないと取り込めない、では使いにくい
		next[sheet.name] = present.has(file)
			? csvToSheet(sheet, readFileSync(path.join(dir, file), "utf8"))
			: current.dataset[sheet.name];
	}

	const result = await session.commitDataset(client, current, next, {
		at: new Date().toISOString(),
		by: "rosheet-cli",
		note: flag(argv, "--note", `import from ${path.basename(dir)}`),
	});
	if (result.changed.length === 0) {
		console.log("CSV は現在値と同じ。commit は積まなかった");
		return;
	}
	console.log(`commit #${result.commit.seq} を積んだ: ${result.changed.join(", ")}`);
	reportWrite(generate.write(current.schema, normalizeDataset(current.schema, next), config, cwd));
}

async function cmdSchema(config, argv, cwd) {
	const schema = await session.readSchema(clientFor(config));
	const save = flag(argv, "--save", null);
	if (save !== null) {
		const target = path.resolve(cwd, save);
		mkdirSync(path.dirname(target), { recursive: true });
		writeFileSync(target, `${JSON.stringify(schema, null, "\t")}\n`, "utf8");
		console.log(`スキーマを書いた: ${target}`);
		return;
	}
	for (const sheet of schema.sheets)
		console.log(`${sheet.name}  (${sheet.kind}${sheet.key === null ? "" : `, key=${sheet.key}`})  ${sheet.columns.length} 列`);
}

async function cmdPlugin(config, argv, cwd) {
	const result = writePlugin(config, { output: flag(argv, "--out", flag(argv, "-o", null)), cwd });
	console.log(`プラグインを書いた: ${result.path}`);
	if (result.intoStudio) console.log("Studio を再起動するか、プラグインを読み込み直す");
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

	const config = loadConfig(cwd);
	switch (command) {
		case "pull":
			return cmdPull(config, argv, cwd);
		case "check":
			return cmdCheck(config, cwd);
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
		case "plugin":
			return cmdPlugin(config, argv, cwd);
		default:
			throw new Error(`知らないコマンド: ${command}（rosheet help）`);
	}
}

main().catch((error) => {
	console.error(`rosheet: ${error.message}`);
	process.exit(1);
});
