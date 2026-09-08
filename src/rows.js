/** 行データの検証・既定値の充填・正規のシリアライズ。
 *
 * ここが「スキーマに合わない値は保存も生成もされない」唯一の関門で、プラグイン・pull・
 * import の全部がここを通る。正規のシリアライズは Apply の差分判定にも使うので、
 * 列の順序はスキーマ順に固定する（キー順が揺れると変更が無くても差分に見える）。
 */

const { checkValue } = require("./schema");

class DataError extends Error {}

function fail(where, message) {
	throw new DataError(`${where}: ${message}`);
}

/** 文字列 1 つを列の型へ寄せる。CSV の取り込みとプラグインのセル編集が共通で使う */
function coerceString(column, raw) {
	const text = typeof raw === "string" ? raw : String(raw);
	switch (column.type) {
		case "string":
		case "text":
		case "enum":
		case "asset":
			return text;
		case "color":
			return text.trim().toUpperCase();
		case "number":
		case "integer": {
			const trimmed = text.trim();
			if (trimmed === "") return column.default;
			const value = Number(trimmed);
			return Number.isNaN(value) ? text : value;
		}
		case "boolean": {
			const trimmed = text.trim().toLowerCase();
			if (trimmed === "true" || trimmed === "1" || trimmed === "yes") return true;
			if (trimmed === "false" || trimmed === "0" || trimmed === "no" || trimmed === "") return false;
			return text;
		}
		default:
			return text;
	}
}

function normalizeRow(sheet, raw, where) {
	if (raw === null || typeof raw !== "object" || Array.isArray(raw)) fail(where, "a row must be an object");
	const row = {};
	for (const column of sheet.columns) {
		const value = raw[column.name] === undefined ? column.default : raw[column.name];
		const problem = checkValue(column, value);
		if (problem !== null) fail(`${where}.${column.name}`, problem);
		row[column.name] = value;
	}
	return row;
}

function normalizeSheetValue(sheet, raw) {
	if (sheet.kind === "scalars") {
		const row = normalizeRow(sheet, raw === undefined || raw === null ? {} : raw, `sheet ${sheet.name}`);
		return row;
	}

	// Studio の JSONEncode は空テーブルを `[]` にするので、ここは本来通る（実測）。
	// それでも受けるのは、空の表がここで落ちると「行を全部消したら二度と読めない」という
	// 直しようのない壊れ方になるため。CSV や手書きの JSON から来る経路もある
	const source = raw === undefined || raw === null ? [] : raw;
	const list = !Array.isArray(source) && typeof source === "object" && Object.keys(source).length === 0 ? [] : source;
	if (!Array.isArray(list)) fail(`sheet ${sheet.name}`, "a table sheet value must be an array");

	const rows = list.map((row, index) => normalizeRow(sheet, row, `sheet ${sheet.name}[${index}]`));
	if (sheet.key !== undefined) {
		const seen = new Set();
		rows.forEach((row, index) => {
			const key = row[sheet.key];
			if (key === "") fail(`sheet ${sheet.name}[${index}]`, `${sheet.key} is empty`);
			if (seen.has(key)) fail(`sheet ${sheet.name}[${index}]`, `duplicate ${sheet.key}: ${key}`);
			seen.add(key);
		});
	}
	return rows;
}

/** スキーマに載っているシートだけを、スキーマ順・列順に揃えて返す */
function normalizeDataset(schema, data) {
	const source = data === undefined || data === null ? {} : data;
	const dataset = {};
	for (const sheet of schema.sheets) dataset[sheet.name] = normalizeSheetValue(sheet, source[sheet.name]);
	return dataset;
}

function emptyDataset(schema) {
	const dataset = {};
	for (const sheet of schema.sheets) dataset[sheet.name] = sheet.kind === "scalars" ? normalizeRow(sheet, {}, sheet.name) : [];
	return dataset;
}

/** 列順をスキーマ順に固定した写し。JSON.stringify のキー順に頼らないのが要点で、
 * 差分判定・blob の同一性・rosheet.lock.json の並びが全部これで一意に決まる */
function orderSheet(sheet, value) {
	return sheet.kind === "scalars"
		? sheet.columns.reduce((acc, column) => ({ ...acc, [column.name]: value[column.name] }), {})
		: value.map((row) => sheet.columns.reduce((acc, column) => ({ ...acc, [column.name]: row[column.name] }), {}));
}

function orderDataset(schema, dataset) {
	return Object.fromEntries(schema.sheets.map((sheet) => [sheet.name, orderSheet(sheet, dataset[sheet.name])]));
}

/** 差分判定と blob の同一性に使う正規形 */
function serializeSheet(sheet, value) {
	return JSON.stringify(orderSheet(sheet, value));
}

module.exports = {
	DataError,
	coerceString,
	normalizeDataset,
	normalizeSheetValue,
	emptyDataset,
	orderSheet,
	orderDataset,
	serializeSheet,
};
