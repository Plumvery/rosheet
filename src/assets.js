/** `asset` 列の `rocas://` を実際のアセット ID へ解決する。
 *
 * 保存先には `rocas://assets/images/maps/SciFi.png` のまま置く。アセットを上げ直すと ID は
 * 変わるが、パスは変わらないため。解決するのは生成のときだけで、place に焼かれるのは
 * 解決済みの `rbxassetid://<n>` になる。
 *
 * 解決できない値を素通しすると、`rocas://...` がそのまま Image に入って「黙って出ない」
 * 壊れ方をする。見つからなければ生成を落とす。
 */

const path = require("node:path");
const { existsSync } = require("node:fs");

const ROCAS_SCHEME = "rocas://";
const ROCAS_PREFIX = "assets/";
const ASSET_ID = /^rbxassetid:\/\/\d+$/;

class AssetError extends Error {}

/** rocas は使っているプロジェクトだけが入れる。無いなら `rocas://` を使わない構成として扱う */
function loadRocas() {
	try {
		return require("@plumvery/rocas");
	} catch {
		return null;
	}
}

function createResolver(cwd = process.cwd()) {
	let byRelativePath = null;

	function assetMap() {
		if (byRelativePath !== null) return byRelativePath;

		const rocas = loadRocas();
		if (rocas === null)
			throw new AssetError(`${ROCAS_SCHEME} を使うには @plumvery/rocas が要る（npm i -D @plumvery/rocas）`);
		if (!existsSync(path.join(cwd, "rocas.toml")))
			throw new AssetError(`${ROCAS_SCHEME} を使うには rocas.toml が要る: ${path.join(cwd, "rocas.toml")}`);

		// lock はリポジトリ内のファイルなので、引いてもネットワークは要らない
		byRelativePath = rocas.buildAssetMap(rocas.loadConfig(cwd), cwd).byRelativePath;
		return byRelativePath;
	}

	return {
		/** 空 / `rbxassetid://<n>` はそのまま。`rocas://assets/...` だけ引き直す */
		resolve(raw, where) {
			const value = typeof raw === "string" ? raw.trim() : "";
			if (value === "" || ASSET_ID.test(value)) return value;
			if (!value.startsWith(ROCAS_SCHEME))
				throw new AssetError(`${where}: 空 / rbxassetid://<数字> / ${ROCAS_SCHEME}assets/... のどれでもない: ${raw}`);

			const relativePath = value.slice(ROCAS_SCHEME.length);
			// byRelativePath は同じ資産に 3 通りのキーを作り、グループ相対のキーは rocas.toml の
			// 記述順で先勝ちになる。assets/ 始まりに限れば cwd 相対のキーしか一致せず、曖昧さが消える
			if (!relativePath.startsWith(ROCAS_PREFIX))
				throw new AssetError(`${where}: ${ROCAS_SCHEME} のパスは ${ROCAS_PREFIX} で始まらなければならない: ${raw}`);

			const assetId = assetMap()[relativePath];
			if (assetId === undefined) throw new AssetError(`${where}: rocas の lock に無い: ${raw}`);
			return assetId;
		},

		/** プラグインへ焼く一覧（補完とサムネイル用）。rocas が無いプロジェクトでは空 */
		entries() {
			const rocas = loadRocas();
			if (rocas === null || !existsSync(path.join(cwd, "rocas.toml"))) return [];

			return Object.entries(rocas.buildAssetMap(rocas.loadConfig(cwd), cwd).byRelativePath)
				.filter(([relativePath]) => relativePath.startsWith(ROCAS_PREFIX))
				.map(([relativePath, assetId]) => ({ path: `${ROCAS_SCHEME}${relativePath}`, assetId }))
				.sort((a, b) => a.path.localeCompare(b.path));
		},
	};
}

/** 生成の直前に、asset 列だけを解決した写しを作る。保存先の値は書き換えない */
function resolveDataset(schema, dataset, resolver) {
	const resolved = {};
	for (const sheet of schema.sheets) {
		const assetColumns = sheet.columns.filter((column) => column.type === "asset");
		const value = dataset[sheet.name];
		if (assetColumns.length === 0) {
			resolved[sheet.name] = value;
			continue;
		}

		if (sheet.kind === "scalars") {
			const row = { ...value };
			for (const column of assetColumns) row[column.name] = resolver.resolve(row[column.name], `${sheet.name}.${column.name}`);
			resolved[sheet.name] = row;
			continue;
		}

		resolved[sheet.name] = value.map((row, index) => {
			const copy = { ...row };
			for (const column of assetColumns)
				copy[column.name] = resolver.resolve(copy[column.name], `${sheet.name}[${index + 1}].${column.name}`);
			return copy;
		});
	}
	return resolved;
}

module.exports = { ROCAS_SCHEME, ROCAS_PREFIX, AssetError, createResolver, resolveDataset };
