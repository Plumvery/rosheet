/** スキーマの正規形と検証。
 *
 * スキーマの著者は Luau / TypeScript でシートと列を宣言し、Studio プラグインがそれを
 * require して JSON へ落とす。この JSON がプラグイン・コード生成・行の検証の共通の正で、
 * CLI は Luau も TypeScript も評価しない（roblox-ts のコンパイル済み出力は Lune から
 * 素直に require できないため、言語ごとの評価器を持つと片方だけ壊れる）。
 */

const COLUMN_TYPES = new Set(["string", "text", "number", "integer", "boolean", "enum", "asset", "color"]);
const SHEET_KINDS = new Set(["table", "scalars"]);
const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;
const ASSET_VALUE = /^rbxassetid:\/\/\d+$/;
const ROCAS_VALUE = /^rocas:\/\/assets\/[^\s]+$/;
const COLOR_VALUE = /^#[0-9A-Fa-f]{6}$/;

class SchemaError extends Error {}

function fail(where, message) {
	throw new SchemaError(`${where}: ${message}`);
}

/** 既定値は「列の型が表せる最も無害な値」。enum だけは無害な既定が決められないので先頭の値を採る */
function implicitDefault(column) {
	switch (column.type) {
		case "number":
		case "integer":
			return 0;
		case "boolean":
			return false;
		case "enum":
			return column.values[0];
		case "color":
			return "#FFFFFF";
		default:
			return "";
	}
}

function normalizeColumn(raw, where) {
	if (raw === null || typeof raw !== "object") fail(where, "a column must be an object");
	const name = raw.name;
	if (typeof name !== "string" || !IDENTIFIER.test(name))
		fail(where, `column name is not a usable identifier: ${JSON.stringify(name)}`);

	const at = `${where}.${name}`;
	const type = raw.type;
	if (!COLUMN_TYPES.has(type)) fail(at, `unsupported column type: ${JSON.stringify(type)}`);

	const column = {
		name,
		type,
		readonly: raw.readonly === true,
		description: typeof raw.description === "string" ? raw.description : "",
	};

	if (type === "enum") {
		const values = raw.values;
		if (!Array.isArray(values) || values.length === 0) fail(at, "enum needs values");
		for (const value of values) if (typeof value !== "string") fail(at, "enum values must all be strings");
		if (new Set(values).size !== values.length) fail(at, "duplicate enum values");
		column.values = [...values];
	}

	if (type === "number" || type === "integer") {
		if (raw.min !== undefined) {
			if (typeof raw.min !== "number" || !Number.isFinite(raw.min)) fail(at, "min is not a finite number");
			column.min = raw.min;
		}
		if (raw.max !== undefined) {
			if (typeof raw.max !== "number" || !Number.isFinite(raw.max)) fail(at, "max is not a finite number");
			column.max = raw.max;
		}
		if (column.min !== undefined && column.max !== undefined && column.min > column.max)
			fail(at, `min is greater than max: ${column.min} > ${column.max}`);
	}

	column.default = raw.default === undefined ? implicitDefault(column) : raw.default;
	const problem = checkValue(column, column.default);
	if (problem !== null) fail(at, `default does not match the column type: ${problem}`);

	return column;
}

function normalizeSheet(raw, where) {
	if (raw === null || typeof raw !== "object") fail(where, "a sheet must be an object");
	const name = raw.name;
	if (typeof name !== "string" || !IDENTIFIER.test(name))
		fail(where, `sheet name is not a usable identifier: ${JSON.stringify(name)}`);

	const at = `sheet ${name}`;
	const kind = raw.kind === undefined ? "table" : raw.kind;
	if (!SHEET_KINDS.has(kind)) fail(at, `unsupported sheet kind: ${JSON.stringify(kind)}`);

	if (!Array.isArray(raw.columns) || raw.columns.length === 0) fail(at, "columns is empty");
	const columns = raw.columns.map((column) => normalizeColumn(column, at));
	const seen = new Set();
	for (const column of columns) {
		if (seen.has(column.name)) fail(at, `duplicate column name: ${column.name}`);
		seen.add(column.name);
	}

	const sheet = {
		name,
		kind,
		description: typeof raw.description === "string" ? raw.description : "",
		columns,
	};

	if (kind === "table") {
		// key を持たない表も許す（スピンホイールの景品のように並び順そのものが意味を持つ表がある）。
		// key が無いときは `key` を持たせない。Luau 側の nil は JSON から消えるので、null を
		// 入れるとプラグインが置いたスキーマと CLI が作るスキーマがバイト単位でずれる
		const key = raw.key === undefined || raw.key === null ? undefined : raw.key;
		if (key !== undefined) {
			const keyColumn = columns.find((column) => column.name === key);
			if (keyColumn === undefined) fail(at, `no such column for key: ${key}`);
			if (keyColumn.type !== "string") fail(at, `the key column must be a string: ${key} is ${keyColumn.type}`);
			sheet.key = key;
		}
		sheet.rows = raw.rows === "fixed" ? "fixed" : "open";
	} else {
		// scalars は 1 列 = 1 定数で、行の増減という概念が無い
		sheet.rows = "fixed";
	}

	return sheet;
}

/** 検証を通った正規形を返す。入力は壊さない */
function normalizeSchema(raw) {
	if (raw === null || typeof raw !== "object") fail("schema", "a schema must be an object");
	if (!Array.isArray(raw.sheets) || raw.sheets.length === 0) fail("schema", "sheets is empty");

	const sheets = raw.sheets.map((sheet, index) => normalizeSheet(sheet, `sheets[${index}]`));
	const seen = new Set();
	for (const sheet of sheets) {
		if (seen.has(sheet.name)) fail("schema", `duplicate sheet name: ${sheet.name}`);
		seen.add(sheet.name);
	}

	// 宣言順のまま持つ。プラグインのシートタブがこの順で並ぶので、並びは著者が決める
	return { version: 1, sheets };
}

/** 値が列の型に合うなら null、合わないなら理由の文字列を返す */
function checkValue(column, value) {
	switch (column.type) {
		case "string":
		case "text":
			return typeof value === "string" ? null : `not a string: ${JSON.stringify(value)}`;
		case "number":
		case "integer": {
			if (typeof value !== "number" || !Number.isFinite(value)) return `not a finite number: ${JSON.stringify(value)}`;
			if (column.type === "integer" && !Number.isInteger(value)) return `not an integer: ${value}`;
			if (column.min !== undefined && value < column.min) return `below min ${column.min}: ${value}`;
			if (column.max !== undefined && value > column.max) return `above max ${column.max}: ${value}`;
			return null;
		}
		case "boolean":
			return typeof value === "boolean" ? null : `not a boolean: ${JSON.stringify(value)}`;
		case "enum":
			if (typeof value !== "string") return `not a string: ${JSON.stringify(value)}`;
			return column.values.includes(value) ? null : `not one of the allowed values: ${JSON.stringify(value)}`;
		case "asset":
			if (typeof value !== "string") return `not a string: ${JSON.stringify(value)}`;
			// 空を許すのは「まだ差し替えていない」を表せないと運用で嘘の ID を入れる羽目になるため。
			// rocas:// は生成のときに解決する（src/assets.js）。保存先にはこの形のまま置く
			if (value === "" || ASSET_VALUE.test(value) || ROCAS_VALUE.test(value)) return null;
			return `not empty, rbxassetid://<number> or rocas://assets/...: ${JSON.stringify(value)}`;
		case "color":
			if (typeof value !== "string") return `not a string: ${JSON.stringify(value)}`;
			return COLOR_VALUE.test(value) ? null : `not #RRGGBB: ${JSON.stringify(value)}`;
		default:
			return `unsupported column type: ${column.type}`;
	}
}

module.exports = { COLUMN_TYPES, SHEET_KINDS, SchemaError, normalizeSchema, normalizeColumn, checkValue, implicitDefault };
