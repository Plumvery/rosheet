/** runtime/ を利用側のプロジェクトへ複製する。
 *
 * node_modules の中の runtime/ には、roblox-ts のプロジェクトから型として届かない。
 * `@plumvery/rosheet/runtime/live` を import すると「typeRoots に無い npm スコープ」で落ち、
 * 言われたとおり typeRoots に `node_modules/@plumvery` を足すと、そのスコープの全パッケージが
 * 暗黙の型ライブラリとしてプログラムに入り、`types` エントリを持たないパッケージ（rosheet 自身
 * と rocas）で TS2688 になる。
 *
 * 届かせるより、rbxtsc と Rojo が元から見ている木の中へ置いた方が短い。rosheet plugin と同じ
 * 「ファイルを書くコマンド」にして、rosheet を上げたら打ち直してもらう。
 */

const { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } = require("fs");
const path = require("path");

const SOURCE_DIR = path.join(__dirname, "..", "runtime");
// --out が無いときに作るフォルダ名。require / import のパスに出るので短くする
const DIR_NAME = "rosheet";

/** Luau は常に要る。.d.ts は roblox-ts のプロジェクトだけ（Rojo だけの木には置かない） */
function filesFor(format) {
	return readdirSync(SOURCE_DIR)
		.sort()
		.filter((name) => name.endsWith(".luau") || (format === "roblox-ts" && name.endsWith(".d.ts")));
}

/** 既定の置き場は生成物の隣。output.dir は Rojo が見ていて git にも載る場所なので、runtime も届く */
function defaultDir(config) {
	return path.join(path.dirname(config.output.dir), DIR_NAME);
}

function normalizeEol(text) {
	return text.replace(/\r\n/g, "\n");
}

function writeRuntime(config, options = {}) {
	const cwd = options.cwd ?? process.cwd();
	const outDir = path.resolve(cwd, options.output ?? defaultDir(config));
	mkdirSync(outDir, { recursive: true });

	const names = filesFor(config.output.format);
	const written = [];
	for (const name of names) {
		const content = normalizeEol(readFileSync(path.join(SOURCE_DIR, name), "utf8"));
		const target = path.join(outDir, name);
		// 中身が同じなら触らない。書き直すと、見張っているツール（Rojo）が毎回同期し直す
		if (existsSync(target) && normalizeEol(readFileSync(target, "utf8")) === content) continue;
		writeFileSync(target, content, "utf8");
		written.push(name);
	}

	return { outDir, written, total: names.length };
}

module.exports = { SOURCE_DIR, DIR_NAME, filesFor, defaultDir, writeRuntime };
