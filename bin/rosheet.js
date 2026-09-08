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
  rosheet plugin            Write the Studio plugin into the local Plugins folder (install it once)
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
	return createClient({ universe: config.project.universe, datastore: config.project.datastore });
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
		console.log(`Generated files match commit #${current.head.seq}`);
		return;
	}
	for (const problem of problems) console.error(`  ${problem}`);
	throw new Error(`Generated files do not match commit #${current.head.seq}. Run 'rosheet pull' and commit the result`);
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

	const after = await session.readCurrent(client);
	reportWrite(generate.write(after.schema, after.dataset, config, cwd));
}

function writeCsv(current, dir) {
	mkdirSync(dir, { recursive: true });
	for (const sheet of current.schema.sheets)
		writeFileSync(path.join(dir, `${sheet.name}.csv`), sheetToCsv(sheet, current.dataset[sheet.name]), "utf8");
	console.log(`Wrote CSV: ${dir} (${current.schema.sheets.length} sheets)`);
}

async function cmdExport(config, argv, cwd) {
	const current = await session.readCurrent(clientFor(config));
	writeCsv(current, path.resolve(cwd, flag(argv, "--csv", "rosheet-csv")));
}

async function cmdImport(config, argv, cwd) {
	const dir = path.resolve(cwd, flag(argv, "--csv", "rosheet-csv"));
	if (!existsSync(dir)) throw new Error(`No such CSV directory: ${dir}`);

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
		console.log("The CSV matches the current values, so no commit was pushed");
		return;
	}
	console.log(`Pushed commit #${result.commit.seq}: ${result.changed.join(", ")}`);
	reportWrite(generate.write(current.schema, normalizeDataset(current.schema, next), config, cwd));
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
		default:
			throw new Error(`Unknown command: ${command} (rosheet help)`);
	}
}

main().catch((error) => {
	console.error(`rosheet: ${error.message}`);
	process.exit(1);
});
