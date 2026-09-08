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
	assert.throws(() => normalizeSchema({ sheets: [] }), /sheets is empty/);
	assert.throws(() => normalizeSchema({ sheets: [{ name: "a", columns: [{ name: "x", type: "nope" }] }] }), /unsupported column type/);
	assert.throws(
		() => normalizeSchema({ sheets: [{ name: "a", columns: [{ name: "x", type: "enum" }] }] }),
		/enum needs values/,
	);
	assert.throws(
		() => normalizeSchema({ sheets: [{ name: "a", key: "x", columns: [{ name: "x", type: "number" }] }] }),
		/the key column must be a string/,
	);
	assert.throws(
		() => normalizeSchema({ sheets: [{ name: "a", columns: [{ name: "x", type: "number", default: "no" }] }] }),
		/default does not match the column type/,
	);
});

test("行は既定値で埋まり、スキーマ違反は落ちる", () => {
	const dataset = normalizeDataset(SCHEMA, { guns: [{ id: "AK" }] });
	assert.deepStrictEqual(dataset.guns[0], { id: "AK", damage: 10, rarity: "Common", enabled: true });
	assert.deepStrictEqual(dataset.round, { SECONDS: 180 });

	assert.throws(() => normalizeDataset(SCHEMA, { guns: [{ id: "A" }, { id: "A" }] }), /duplicate id/);
	assert.throws(() => normalizeDataset(SCHEMA, { guns: [{ id: "A", damage: -1 }] }), /below min 0/);
	assert.throws(() => normalizeDataset(SCHEMA, { guns: [{ id: "A", rarity: "Nope" }] }), /not one of the allowed values/);
	assert.throws(() => normalizeDataset(SCHEMA, { guns: [{ id: "" }] }), /id is empty/);
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
	assert.throws(() => store.checkSheetNames({ sheets: [{ name: "a".repeat(60) }] }), /Sheet name is too long/);
	assert.throws(() => entryUrl(1, "ds", "a/b"), /A key cannot contain \//);
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

test("空の表が {} で読み戻っても壊れない", () => {
	// Roblox の JSONEncode は空テーブルを {} と [] のどちらで書くか場面で変わる
	assert.deepStrictEqual(normalizeDataset(SCHEMA, { guns: {} }).guns, []);
	assert.deepStrictEqual(normalizeDataset(SCHEMA, { guns: [] }).guns, []);
	assert.throws(() => normalizeDataset(SCHEMA, { guns: { a: 1 } }), /a table sheet value must be an array/);
});

test("プラグインは Script 1 つと ModuleScript の木になる", () => {
	const { buildPlugin } = require("../src/studio-plugin");
	// 設定を渡さない。プラグインには何も焼かないので、どのプロジェクトでも同じものが出る
	const xml = buildPlugin();

	const classes = [...xml.matchAll(/<Item class="(\w+)"/g)].map((match) => match[1]);
	const names = [...xml.matchAll(/<string name="Name">([^<]+)<\/string>/g)].map((match) => match[1]);

	assert.strictEqual(classes[0], "Script");
	assert.ok(classes.slice(1).every((className) => className === "ModuleScript"));
	assert.deepStrictEqual(names[0], "rosheet");
	for (const required of ["Place", "App", "Grid", "Session", "Store", "Live"]) assert.ok(names.includes(required), required);
	// 焼いた設定とアセット一覧はもう無い
	for (const gone of ["Config", "Assets"]) assert.ok(!names.includes(gone), gone);
	// .rbxm を避けた理由がこれ。rbxm-parser は Script.Source の非 ASCII を壊す
	assert.ok(xml.includes("rosheet の Studio プラグイン"));
	assert.strictEqual((xml.match(/<!\[CDATA\[/g) || []).length, (xml.match(/\]\]>/g) || []).length);
});

test("asset 列は rocas:// も受ける", () => {
	const schema = normalizeSchema({ sheets: [{ name: "s", columns: [{ name: "icon", type: "asset" }] }] });
	const column = schema.sheets[0].columns[0];
	const { checkValue } = require("../src/schema");

	assert.strictEqual(checkValue(column, ""), null);
	assert.strictEqual(checkValue(column, "rbxassetid://123"), null);
	assert.strictEqual(checkValue(column, "rocas://assets/images/maps/SciFi.png"), null);
	assert.match(checkValue(column, "rocas://images/maps/SciFi.png"), /not empty, rbxassetid/);
	assert.match(checkValue(column, "SciFi.png"), /not empty, rbxassetid/);
});

test("生成の直前に asset を解決し、解決できない値は落とす", () => {
	const { resolveDataset, createResolver, AssetError } = require("../src/assets");
	const schema = normalizeSchema({
		sheets: [
			{ name: "s", key: "id", columns: [{ name: "id", type: "string" }, { name: "icon", type: "asset" }] },
			{ name: "plain", key: "id", columns: [{ name: "id", type: "string" }] },
		],
	});
	const dataset = normalizeDataset(schema, {
		s: [{ id: "a", icon: "rocas://assets/images/a.png" }, { id: "b", icon: "rbxassetid://7" }, { id: "c" }],
		plain: [{ id: "z" }],
	});

	const stub = { resolve: (value) => (value.startsWith("rocas://") ? "rbxassetid://99" : value) };
	const resolved = resolveDataset(schema, dataset, stub);
	assert.deepStrictEqual(
		resolved.s.map((row) => row.icon),
		["rbxassetid://99", "rbxassetid://7", ""],
	);
	// asset 列を持たないシートはそのまま返す（写しを作らない）
	assert.strictEqual(resolved.plain, dataset.plain);

	// rocas が無い環境では、rocas:// を解決しようとした時点で落ちる
	const real = createResolver(__dirname);
	assert.strictEqual(real.resolve("", "x"), "");
	assert.strictEqual(real.resolve("rbxassetid://5", "x"), "rbxassetid://5");
	assert.throws(() => real.resolve("rocas://images/a.png", "x"), AssetError);
});

// --- Release に添付するインストーラー ---

const {
	MACOS_INSTALLER_NAME,
	PAYLOAD_MARKER,
	buildMacInstaller,
	buildWindowsInstaller,
	createZip,
} = require("../scripts/build-installers");
const { DEFAULT_PLUGIN_FILE } = require("../src/studio-plugin");

// 76 桁で折り返すので、1 行に収まらない長さを渡す
const INSTALLER_PAYLOAD = Buffer.from(Array.from({ length: 300 }, (_, index) => (index * 7) % 256));

// インストーラーは自分自身をマーカー行で切って後ろを decode する。マーカーだけの行が
// 2 本あると、切る位置が変わって壊れる
function extractPayload(script) {
	const lines = script.split(/\r?\n/);
	assert.strictEqual(lines.filter((line) => line === PAYLOAD_MARKER).length, 1, "マーカーだけの行は 1 本");
	return Buffer.from(lines.slice(lines.indexOf(PAYLOAD_MARKER) + 1).join(""), "base64");
}

test("Windows のインストーラーは CRLF で、Plugins フォルダへ書く", () => {
	const installer = buildWindowsInstaller(INSTALLER_PAYLOAD);

	assert(installer.startsWith("@echo off\r\n"));
	// cmd.exe の括弧ブロックは LF だけだと崩れることがある
	assert.deepStrictEqual(
		installer.split("\n").filter((line) => line !== "" && !line.endsWith("\r")),
		[],
	);
	assert(installer.includes("Join-Path $env:LOCALAPPDATA 'Roblox\\Plugins'"));
	// `rosheet plugin` と同じファイル名。変えると同じプラグインが 2 つ読み込まれる
	assert(installer.includes(`Join-Path $dir '${DEFAULT_PLUGIN_FILE}'`));
	// マーカーの手前で抜けないと、cmd が base64 をコマンドとして読む
	assert(installer.indexOf("\r\nexit /b\r\n") < installer.lastIndexOf(PAYLOAD_MARKER));
	assert(extractPayload(installer).equals(INSTALLER_PAYLOAD));
});

test("macOS のインストーラーは LF で、Documents の Plugins フォルダへ書く", () => {
	const installer = buildMacInstaller(INSTALLER_PAYLOAD);

	assert(installer.startsWith("#!/bin/bash\n"));
	assert(!installer.includes("\r"));
	assert(installer.includes('dir="$HOME/Documents/Roblox/Plugins"'));
	assert(installer.includes(`file="$dir/${DEFAULT_PLUGIN_FILE}"`));
	// awk のパターンは行頭行末で留める。留めないと、awk を呼ぶ行そのものに当たる
	assert(installer.includes(`/^${PAYLOAD_MARKER}$/`));
	assert(installer.indexOf("\nexit 0\n") < installer.lastIndexOf(PAYLOAD_MARKER));
	assert(extractPayload(installer).equals(INSTALLER_PAYLOAD));
});

test("mac 版を包む zip は実行ビットを残す", () => {
	const installer = Buffer.from(buildMacInstaller(INSTALLER_PAYLOAD), "utf8");
	const zip = createZip([{ name: MACOS_INSTALLER_NAME, data: installer, mode: 0o755 }]);

	const eocd = zip.length - 22;
	assert.strictEqual(zip.readUInt32LE(eocd), 0x06054b50);
	assert.strictEqual(zip.readUInt16LE(eocd + 8), 1);

	const central = zip.readUInt32LE(eocd + 16);
	assert.strictEqual(zip.readUInt32LE(central), 0x02014b50);
	// version made by の上位バイトが 3 (UNIX) でないと、展開側がモードを見ない
	assert.strictEqual(zip.readUInt16LE(central + 4) >>> 8, 3);
	assert.strictEqual(zip.readUInt32LE(central + 38) >>> 16, 0o100755);

	const nameLength = zip.readUInt16LE(central + 28);
	assert.strictEqual(zip.subarray(central + 46, central + 46 + nameLength).toString(), MACOS_INSTALLER_NAME);
	// 無圧縮なので、格納したバイト列がそのまま入っている
	assert(zip.includes(installer));
});
