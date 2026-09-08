/** Luau 側と JS 側のスキーマ正規化が一致するか。
 *
 * test/normalize.test.luau が Luau 側の結果を build/schema.luau.json に書く。ここではそれを
 * JS 側の normalizeSchema へ通し、通す前と一致するかを見る。正規形どうしなので、一致しないなら
 * どちらかの規則がずれている。
 *
 * 実行: lune run test/normalize.test.luau && node test/cross-check.js
 */

const assert = require("node:assert");
const { readFileSync, existsSync } = require("node:fs");
const path = require("node:path");
const { normalizeSchema } = require("../src/schema");

const INPUT = path.join(__dirname, "..", "build", "schema.luau.json");

if (!existsSync(INPUT)) {
	console.error(`${INPUT} が無い。先に 'lune run test/normalize.test.luau' を実行する`);
	process.exit(1);
}

const fromLuau = JSON.parse(readFileSync(INPUT, "utf8"));
const fromJs = normalizeSchema(fromLuau);

// JSON を経由して比べる。Luau 側に無いキーは undefined として落ちるので、そこも揃っていないと通らない
assert.deepStrictEqual(JSON.parse(JSON.stringify(fromJs)), fromLuau, "Luau 側と JS 側の正規形が違う");

const sheets = fromLuau.sheets.map((sheet) => `${sheet.name}(${sheet.kind}, ${sheet.columns.length}列)`);
console.log(`ok    正規形が一致: ${sheets.join(" / ")}`);
