const test = require("node:test");
const assert = require("node:assert");

const { normalizeSchema } = require("../src/schema");
const { normalizeDataset, serializeSheet, coerceString } = require("../src/rows");
const { generateLuau, generateDts } = require("../src/codegen");
const { sheetToCsv, csvToSheet, parse } = require("../src/csv");
const { parseToml, normalizeConfig } = require("../src/config");
const store = require("../src/store");
const { render } = require("../src/rbxmx");
const { entryUrl } = require("../src/opencloud");

const SCHEMA = normalizeSchema({
	sheets: [
		{
			name: "guns",
			key: "id",
			columns: [
				{ name: "id", type: "string", readonly: true },
				{ name: "damage", type: "number", default: 10, min: 0 },
				{ name: "rarity", type: "enum", values: ["Common", "Rare"] },
				{ name: "enabled", type: "boolean", default: true },
			],
		},
		{ name: "round", kind: "scalars", columns: [{ name: "SECONDS", type: "integer", default: 180 }] },
	],
});

test("スキーマは宣言順を保つ", () => {
	assert.deepStrictEqual(
		SCHEMA.sheets.map((sheet) => sheet.name),
		["guns", "round"],
	);
});

test("スキーマは壊れた宣言を弾く", () => {
	assert.throws(() => normalizeSchema({ sheets: [] }), /sheets が空/);
	assert.throws(() => normalizeSchema({ sheets: [{ name: "a", columns: [{ name: "x", type: "nope" }] }] }), /未対応の列の型/);
	assert.throws(
		() => normalizeSchema({ sheets: [{ name: "a", columns: [{ name: "x", type: "enum" }] }] }),
		/enum には values が要る/,
	);
	assert.throws(
		() => normalizeSchema({ sheets: [{ name: "a", key: "x", columns: [{ name: "x", type: "number" }] }] }),
		/key の列は string/,
	);
	assert.throws(
		() => normalizeSchema({ sheets: [{ name: "a", columns: [{ name: "x", type: "number", default: "no" }] }] }),
		/default が列の型に合わない/,
	);
});

test("行は既定値で埋まり、スキーマ違反は落ちる", () => {
	const dataset = normalizeDataset(SCHEMA, { guns: [{ id: "AK" }] });
	assert.deepStrictEqual(dataset.guns[0], { id: "AK", damage: 10, rarity: "Common", enabled: true });
	assert.deepStrictEqual(dataset.round, { SECONDS: 180 });

	assert.throws(() => normalizeDataset(SCHEMA, { guns: [{ id: "A" }, { id: "A" }] }), /id が重複している/);
	assert.throws(() => normalizeDataset(SCHEMA, { guns: [{ id: "A", damage: -1 }] }), /min 0 を下回る/);
	assert.throws(() => normalizeDataset(SCHEMA, { guns: [{ id: "A", rarity: "Nope" }] }), /enum に無い値/);
	assert.throws(() => normalizeDataset(SCHEMA, { guns: [{ id: "" }] }), /id が空/);
});

test("正規のシリアライズは列の順序で決まり、キーの並びに揺れない", () => {
	const a = serializeSheet(SCHEMA.sheets[0], [{ id: "A", damage: 1, rarity: "Rare", enabled: false }]);
	const b = serializeSheet(SCHEMA.sheets[0], [{ enabled: false, rarity: "Rare", damage: 1, id: "A" }]);
	assert.strictEqual(a, b);
});

test("Luau の生成物は文字列を正しく逃がす", () => {
	const luau = generateLuau(SCHEMA.sheets[0], [{ id: 'a"b\\c\nd', damage: 1, rarity: "Rare", enabled: true }]);
	assert.match(luau, /^--!strict\n/);
	assert.ok(luau.includes('id = "a\\"b\\\\c\\nd"'));
	assert.ok(luau.includes("get = function(id: string): Row?"));
	assert.ok(luau.includes('export type Rarity = "Common" | "Rare"'));
});

test("scalars は table.freeze した 1 枚のテーブルになる", () => {
	const luau = generateLuau(SCHEMA.sheets[1], { SECONDS: 90 });
	assert.ok(luau.includes("SECONDS = 90,"));
	assert.ok(luau.includes("return table.freeze(scalars)"));
	assert.ok(!luau.includes("byId"));
});

test("d.ts は列の型と索引を出す", () => {
	const dts = generateDts(SCHEMA.sheets[0]);
	assert.ok(dts.includes("readonly damage: number;"));
	assert.ok(dts.includes("export declare const byId: { readonly [id: string]: Row | undefined };"));
	assert.ok(generateDts(SCHEMA.sheets[1]).includes("export declare const SECONDS: number;"));
});

test("CSV は往復しても値が変わらない", () => {
	const dataset = normalizeDataset(SCHEMA, {
		guns: [
			{ id: "AK", damage: 34, rarity: "Rare", enabled: false },
			{ id: 'q"uote,comma', damage: 1 },
		],
	});
	for (const sheet of SCHEMA.sheets) {
		const csv = sheetToCsv(sheet, dataset[sheet.name]);
		assert.deepStrictEqual(normalizeDataset(SCHEMA, { [sheet.name]: csvToSheet(sheet, csv) })[sheet.name], dataset[sheet.name]);
	}
});

test("CSV の BOM と CRLF を落とす", () => {
	assert.deepStrictEqual(parse("﻿a,b\r\n1,2\r\n"), [
		["a", "b"],
		["1", "2"],
	]);
});

test("文字列から列の型への寄せ方", () => {
	const [, damage, , enabled] = SCHEMA.sheets[0].columns;
	assert.strictEqual(coerceString(damage, " 12 "), 12);
	assert.strictEqual(coerceString(damage, ""), 10);
	assert.strictEqual(coerceString(enabled, "TRUE"), true);
	assert.strictEqual(coerceString(enabled, "0"), false);
});

test("TOML は必要な部分だけ読む", () => {
	const config = normalizeConfig(
		parseToml(
			['[project]', 'universe = 10_749_582_267  # comment', 'datastore = "rosheet"', "", "[output]", 'dir = "out"'].join(
				"\n",
			),
			"t",
		),
		"t",
	);
	assert.strictEqual(config.project.universe, 10749582267);
	assert.strictEqual(config.output.format, "luau");
	assert.strictEqual(config.output.dir, "out");
	assert.throws(() => normalizeConfig(parseToml('[output]\nformat = "nope"\ndir = "o"', "t"), "t"), /output.format/);
});

test("commit は変わったシートだけ新しい blob を作る", () => {
	const before = { guns: '[{"id":"A"}]', round: '{"SECONDS":180}' };
	const after = { guns: '[{"id":"B"}]', round: '{"SECONDS":180}' };
	const first = store.planCommit(SCHEMA, store.emptyCommit(), { guns: "", round: "" }, before, { at: "t", by: "me" });
	assert.deepStrictEqual(first.changed, ["guns", "round"]);
	assert.strictEqual(first.commit.seq, 1);

	const second = store.planCommit(SCHEMA, first.commit, before, after, { at: "t", by: "me" });
	assert.deepStrictEqual(second.changed, ["guns"]);
	assert.deepStrictEqual(second.commit.sheets, { guns: 2, round: 1 });
	assert.strictEqual(second.blobs.length, 1);
});

test("巻き戻しは新しい commit として前へ積む", () => {
	const target = { seq: 3, sheets: { guns: 3, round: 1 } };
	const head = { seq: 7, sheets: { guns: 7, round: 5 } };
	const plan = store.planRevert(head, target, { at: "t", by: "me" });
	assert.strictEqual(plan.commit.seq, 8);
	assert.strictEqual(plan.commit.parent, 7);
	assert.strictEqual(plan.commit.revertOf, 3);
	assert.deepStrictEqual(plan.commit.sheets, target.sheets);
	assert.strictEqual(plan.blobs.length, 0);
});

test("DataStore のキーは 50 文字と / の制約を守る", () => {
	assert.ok(store.blobKey(999999, "a".repeat(store.MAX_SHEET_NAME)).length <= store.MAX_KEY_LENGTH);
	assert.ok(!store.commitKey(1).includes("/"));
	assert.throws(() => store.checkSheetNames({ sheets: [{ name: "a".repeat(60) }] }), /シート名が長すぎる/);
	assert.throws(() => entryUrl(1, "ds", "a/b"), /キーに \/ を含められない/);
});

test("log は新しい順で件数を切る", () => {
	let log = { entries: [] };
	for (let seq = 1; seq <= store.LOG_LIMIT + 5; seq++) log = store.appendLog(log, { seq, at: "t", by: "me", note: "" }, ["guns"]);
	assert.strictEqual(log.entries.length, store.LOG_LIMIT);
	assert.strictEqual(log.entries[0].seq, store.LOG_LIMIT + 5);
});

test("rbxmx は CDATA を閉じさせない", () => {
	const xml = render({ className: "Script", name: "p", source: 'local s = "]]>"', children: [] });
	assert.ok(xml.includes("]]]]><![CDATA[>"));
	assert.ok(!xml.includes('"]]>"'));
	assert.ok(xml.includes('<Item class="Script" referent="RBX0">'));
});
