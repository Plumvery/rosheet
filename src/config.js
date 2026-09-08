/** rosheet.toml と .env の読み込み。
 *
 * TOML は必要な部分だけを自前で読む。rocas と同じ判断で、設定ファイル 1 枚のために
 * 依存を増やさない（この CLI は Roblox プロジェクトの devDependency に入るので、
 * 依存が増えるほど入れてもらいにくくなる）。
 */

const { readFileSync, existsSync } = require("fs");
const path = require("path");

const CONFIG_FILE = "rosheet.toml";
const DEFAULT_DATASTORE = "rosheet";
const FORMATS = new Set(["luau", "roblox-ts"]);

class ConfigError extends Error {}

function parseScalar(raw, where) {
	const text = raw.trim();
	if (text.startsWith('"') && text.endsWith('"') && text.length >= 2) return text.slice(1, -1);
	if (text.startsWith("'") && text.endsWith("'") && text.length >= 2) return text.slice(1, -1);
	if (text === "true") return true;
	if (text === "false") return false;
	// 桁区切りの _ は TOML の数値表記。universe id が長いので実際に書かれる
	const numeric = text.replace(/_/g, "");
	if (/^-?\d+$/.test(numeric)) return Number(numeric);
	if (/^-?\d+\.\d+$/.test(numeric)) return Number(numeric);
	throw new ConfigError(`${where}: not a readable value: ${raw}`);
}

function stripComment(line) {
	let quote = null;
	for (let i = 0; i < line.length; i++) {
		const char = line[i];
		if (quote !== null) {
			if (char === quote) quote = null;
		} else if (char === '"' || char === "'") quote = char;
		else if (char === "#") return line.slice(0, i);
	}
	return line;
}

/** [table] と key = value だけを読む。配列や入れ子テーブルは rosheet.toml に要らない */
function parseToml(text, where) {
	const config = {};
	let table = config;

	text.split(/\r?\n/).forEach((rawLine, index) => {
		const line = stripComment(rawLine).trim();
		if (line === "") return;
		const at = `${where}:${index + 1}`;

		const section = /^\[([A-Za-z0-9_.-]+)\]$/.exec(line);
		if (section !== null) {
			table = {};
			config[section[1]] = table;
			return;
		}

		const pair = /^([A-Za-z0-9_-]+)\s*=\s*(.+)$/.exec(line);
		if (pair === null) throw new ConfigError(`${at}: neither [table] nor key = value: ${rawLine.trim()}`);
		table[pair[1]] = parseScalar(pair[2], at);
	});

	return config;
}

function normalizeConfig(raw, where) {
	const project = raw.project ?? {};
	const output = raw.output ?? {};

	const format = output.format ?? "luau";
	if (!FORMATS.has(format)) throw new ConfigError(`${where}: output.format must be one of ${[...FORMATS].join(" / ")}: ${format}`);
	if (typeof output.dir !== "string" || output.dir === "") throw new ConfigError(`${where}: output.dir is required`);
	if (project.universe !== undefined && typeof project.universe !== "number")
		throw new ConfigError(`${where}: project.universe must be a number`);
	// scope はキースペースを分ける。空文字は「既定の global」と区別が付かないので受けない
	// （黙って捨てると、プラグインと CLI が別のデータを見ていることに気づけない）
	if (project.scope !== undefined && (typeof project.scope !== "string" || project.scope === ""))
		throw new ConfigError(`${where}: project.scope must be a non-empty string`);

	return {
		project: {
			universe: project.universe,
			datastore: project.datastore ?? DEFAULT_DATASTORE,
			scope: project.scope,
		},
		output: {
			format,
			dir: output.dir,
		},
	};
}

function loadConfig(cwd = process.cwd()) {
	const file = path.join(cwd, CONFIG_FILE);
	if (!existsSync(file)) throw new ConfigError(`${CONFIG_FILE} not found: ${file}`);
	return normalizeConfig(parseToml(readFileSync(file, "utf8"), CONFIG_FILE), CONFIG_FILE);
}

/** .env は「あれば読む」。CI では環境変数で渡されるので、無くても失敗にしない */
function loadEnv(cwd = process.cwd()) {
	const file = path.join(cwd, ".env");
	if (!existsSync(file)) return;
	for (const rawLine of readFileSync(file, "utf8").split(/\r?\n/)) {
		const line = rawLine.trim();
		if (line === "" || line.startsWith("#")) continue;
		const pair = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
		if (pair === null) continue;
		if (process.env[pair[1]] === undefined) process.env[pair[1]] = parseScalar(pair[2] === "" ? '""' : pair[2], ".env");
	}
}

module.exports = { CONFIG_FILE, DEFAULT_DATASTORE, ConfigError, loadConfig, loadEnv, parseToml, normalizeConfig };
