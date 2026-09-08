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

test("scope は URL のキースペースに出る", () => {
	// scope を捨てると、プラグインの GetDataStore(name, scope) と別のキースペースを見る
	assert.strictEqual(entryUrl(7, "ds", "head"), "https://apis.roblox.com/cloud/v2/universes/7/data-stores/ds/entries/head");
	assert.strictEqual(
		entryUrl(7, "ds", "head", "master"),
		"https://apis.roblox.com/cloud/v2/universes/7/data-stores/ds/scopes/master/entries/head",
	);
	// 黙って捨てると「プラグインでは編集できているのに pull が何も見つけない」になるので、空は弾く
	assert.throws(() => normalizeConfig(parseToml('[project]\nscope = ""\n[output]\ndir = "o"', "t"), "t"), /project.scope/);
});

test("tag は名前を検査し、重複は force でだけ動く", () => {
	assert.strictEqual(store.checkTagName("v0.3.0"), "v0.3.0");
	// `tag.<name>` を 1 キーにしないので、キーに使えない / を含む名前も通る
	assert.strictEqual(store.checkTagName("release/1.0"), "release/1.0");
	assert.throws(() => store.checkTagName("-nope"), /must start with a letter or digit/);
	assert.throws(() => store.checkTagName("a".repeat(store.MAX_TAG_NAME + 1)), /up to 64 characters/);

	let tags = store.putTag(store.emptyTags(), { name: "v1", seq: 4 });
	assert.strictEqual(store.findTag(tags, "v1").seq, 4);
	assert.throws(() => store.putTag(tags, { name: "v1", seq: 9 }), /already points at #4/);

	tags = store.putTag(tags, { name: "v1", seq: 9 }, { force: true });
	assert.strictEqual(tags.entries.length, 1);
	assert.strictEqual(store.findTag(tags, "v1").seq, 9);

	// pin の基準は「作った順」ではなく「指している commit が一番新しい」もの
	tags = store.putTag(tags, { name: "v0", seq: 2 });
	assert.strictEqual(store.latestTag(tags).name, "v1");
});

test("生成物のヘッダに出所を焼く（時刻は焼かない）", () => {
	const luau = generateLuau(SCHEMA.sheets[1], { SECONDS: 90 }, { source: "commit #42 (v0.3.0)" });
	assert.ok(luau.includes('-- Generated by rosheet from sheet "round" at commit #42 (v0.3.0). Do not edit by hand.'));
	assert.ok(generateDts(SCHEMA.sheets[0], { source: "commit #42" }).includes('sheet "guns" at commit #42.'));
	// 出所が無ければ今までどおり。lock を作っていないプロジェクトの生成物は変わらない
	assert.ok(generateLuau(SCHEMA.sheets[1], { SECONDS: 90 }).includes('from sheet "round". Do not edit'));
});

test("lock はスキーマと値ごと往復し、ネットワーク無しで生成できる", () => {
	const { mkdtempSync, writeFileSync, readFileSync } = require("node:fs");
	const { tmpdir } = require("node:os");
	const nodePath = require("node:path");
	const lock = require("../src/lock");
	const generate = require("../src/generate");

	const cwd = mkdtempSync(nodePath.join(tmpdir(), "rosheet-"));
	const dataset = normalizeDataset(SCHEMA, { guns: [{ id: "AK", damage: 34 }], round: { SECONDS: 90 } });
	const built = lock.buildLock({
		schema: SCHEMA,
		dataset,
		commit: { seq: 42, at: "2026-01-01T00:00:00Z", by: "me", note: "balance" },
		tag: "v0.3.0",
	});

	assert.strictEqual(lock.readLock(cwd), null);
	lock.writeLock(cwd, built);

	const opened = lock.loadLock(cwd);
	assert.strictEqual(lock.sourceLabel(opened.lock), "commit #42 (v0.3.0)");
	assert.deepStrictEqual(opened.dataset, dataset);
	// 列順はスキーマ順に固定する。差分が値の変更だけを映すように
	assert.deepStrictEqual(Object.keys(built.sheets.guns[0]), ["id", "damage", "rarity", "enabled"]);

	// lock だけで生成 → 同じ lock で check が通る。ここが「キー無しで CI が回る」の実体
	const config = { output: { format: "luau", dir: "out" } };
	const source = lock.sourceLabel(opened.lock);
	generate.write(opened.schema, opened.dataset, config, cwd, { source });
	assert.deepStrictEqual(generate.check(opened.schema, opened.dataset, config, cwd, { source }), []);
	assert.ok(readFileSync(nodePath.join(cwd, "out", "guns.luau"), "utf8").includes("at commit #42 (v0.3.0)"));

	// 手で値を直したシートは status が名指しできる
	const edited = normalizeDataset(SCHEMA, { guns: [{ id: "AK", damage: 1 }], round: { SECONDS: 90 } });
	assert.deepStrictEqual(lock.modifiedSheets(SCHEMA, opened.dataset, edited), ["guns"]);

	// 壊れた lock は開いた時点で落とす。生成物に化けさせない
	writeFileSync(nodePath.join(cwd, lock.LOCK_FILE), JSON.stringify({ ...built, version: 99 }), "utf8");
	assert.throws(() => lock.loadLock(cwd), /unsupported version/);
});

test("head 以外の commit もそのまま読める（tag を焼くための経路）", async () => {
	const session = require("../src/session");

	// 偽の DataStore。過去の commit と blob は書き換わらないので、seq を指せば読める
	const entries = new Map();
	const client = {
		async get(key) {
			return entries.has(key) ? entries.get(key) : null;
		},
		async set(key, value) {
			entries.set(key, value);
		},
	};

	await client.set(store.SCHEMA_KEY, SCHEMA);
	await client.set(store.HEAD_KEY, { seq: 2 });
	await client.set(store.commitKey(1), { seq: 1, parent: null, at: "t1", by: "me", note: "", sheets: { guns: 1, round: 1 } });
	await client.set(store.commitKey(2), { seq: 2, parent: 1, at: "t2", by: "me", note: "", sheets: { guns: 2, round: 1 } });
	await client.set(store.blobKey(1, "guns"), [{ id: "AK", damage: 10, rarity: "Common", enabled: true }]);
	await client.set(store.blobKey(2, "guns"), [{ id: "AK", damage: 99, rarity: "Common", enabled: true }]);
	await client.set(store.blobKey(1, "round"), { SECONDS: 180 });

	assert.strictEqual((await session.readCurrent(client)).dataset.guns[0].damage, 99);
	// 出荷を止めるのはこれ。head が進んでも、pin が指す seq の値はそのまま取れる
	const pinned = await session.readAt(client, 1);
	assert.strictEqual(pinned.dataset.guns[0].damage, 10);
	assert.strictEqual(pinned.commit.seq, 1);

	assert.deepStrictEqual(await session.readTags(client), store.emptyTags());
	await session.writeTags(client, store.putTag(store.emptyTags(), { name: "v1", seq: 1, at: "t", by: "me", note: "" }));
	assert.strictEqual(store.findTag(await session.readTags(client), "v1").seq, 1);
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

test("runtime は format に合わせて利用側へ複製する", () => {
	const { mkdtempSync, readdirSync } = require("node:fs");
	const { tmpdir } = require("node:os");
	const nodePath = require("node:path");
	const { writeRuntime, filesFor } = require("../src/runtime");

	// roblox-ts のプロジェクトから node_modules の .d.ts へは届かないので、src/ の中へ写す
	assert.ok(filesFor("roblox-ts").includes("live.d.ts"));
	assert.ok(!filesFor("luau").some((name) => name.endsWith(".d.ts")));
	// README の require(Packages.rosheet) が通るための集約モジュール
	assert.ok(filesFor("luau").includes("init.luau"));

	const cwd = mkdtempSync(nodePath.join(tmpdir(), "rosheet-"));
	const config = { output: { format: "luau", dir: "src/shared/config/generated" } };

	const first = writeRuntime(config, { cwd });
	assert.strictEqual(nodePath.relative(cwd, first.outDir), nodePath.join("src", "shared", "config", "rosheet"));
	assert.deepStrictEqual(readdirSync(first.outDir).sort(), filesFor("luau"));

	// 2 回目は書かない。書き直すと Rojo が毎回同期し直す
	assert.deepStrictEqual(writeRuntime(config, { cwd }).written, []);

	const typed = writeRuntime({ output: { format: "roblox-ts", dir: "out" } }, { cwd, output: "src/shared/rosheet" });
	assert.strictEqual(nodePath.relative(cwd, typed.outDir), nodePath.join("src", "shared", "rosheet"));
	assert.deepStrictEqual(readdirSync(typed.outDir).sort(), filesFor("roblox-ts"));
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
