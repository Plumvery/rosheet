/** CSV の読み書き。
 *
 * CSV は rosheet の経路の外にある。編集の正は Studio + DataStore で、出荷の正は生成物なので、
 * ここは「スプレッドシートや外部ツールと往復するための出入口」だけを担う。
 * 型は CSV に書かない（スキーマが持っている）。1 行目は列名、2 行目以降がデータ。
 */

const { coerceString } = require("./rows");

function needsQuote(field) {
	return /[",\r\n]/.test(field);
}

function encodeField(value) {
	const text = typeof value === "boolean" ? (value ? "true" : "false") : String(value);
	return needsQuote(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function encodeRows(rows) {
	return `${rows.map((row) => row.map(encodeField).join(",")).join("\n")}\n`;
}

/** RFC 4180。BOM は Excel が付けるので落とす */
function parse(text) {
	const source = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
	const rows = [];
	let row = [];
	let field = "";
	let quoted = false;

	for (let i = 0; i < source.length; i++) {
		const char = source[i];
		if (quoted) {
			if (char !== '"') {
				field += char;
			} else if (source[i + 1] === '"') {
				field += '"';
				i++;
			} else {
				quoted = false;
			}
			continue;
		}
		if (char === '"') quoted = true;
		else if (char === ",") {
			row.push(field);
			field = "";
		} else if (char === "\n" || char === "\r") {
			if (char === "\r" && source[i + 1] === "\n") i++;
			row.push(field);
			rows.push(row);
			row = [];
			field = "";
		} else field += char;
	}
	if (field !== "" || row.length > 0) {
		row.push(field);
		rows.push(row);
	}

	return rows.filter((cells) => !(cells.length === 1 && cells[0] === ""));
}

function sheetToCsv(sheet, value) {
	if (sheet.kind === "scalars")
		return encodeRows([["key", "value"], ...sheet.columns.map((column) => [column.name, value[column.name]])]);

	const header = sheet.columns.map((column) => column.name);
	return encodeRows([header, ...value.map((row) => header.map((name) => row[name]))]);
}

function csvToSheet(sheet, text) {
	const rows = parse(text);
	if (rows.length === 0) return sheet.kind === "scalars" ? {} : [];

	const byName = new Map(sheet.columns.map((column) => [column.name, column]));

	if (sheet.kind === "scalars") {
		const value = {};
		for (const [name, raw] of rows.slice(1)) {
			const column = byName.get(name);
			// スキーマに無い行は落とす。列を消したときに CSV 側の消し忘れで取り込みが落ちないように
			if (column !== undefined) value[column.name] = coerceString(column, raw ?? "");
		}
		return value;
	}

	const header = rows[0];
	return rows.slice(1).map((cells) => {
		const row = {};
		header.forEach((name, index) => {
			const column = byName.get(name);
			if (column !== undefined) row[column.name] = coerceString(column, cells[index] ?? "");
		});
		return row;
	});
}

module.exports = { parse, encodeRows, sheetToCsv, csvToSheet };
