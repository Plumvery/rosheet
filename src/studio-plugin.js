/** plugin/src/*.luau を 1 つの .rbxmx にまとめて Studio の Plugins フォルダへ置く。
 *
 * 束ねずに ModuleScript の木のまま入れる。バンドラで require を書き換えると、Studio 側で出た
 * エラーの行番号がリポジトリのファイルと合わなくなり、UI の作り込みで一番効く手掛かりを失う。
 *
 * プラグインには何も焼かない。スキーマも保存先も rocas のアセット一覧も、place の中から読む
 * （plugin/src/Place.luau）。焼くと、値を変えるたび・アセットを足すたびに入れ直すことになる。
 * 入れ直しが要らないぶん、プラグインは全プロジェクトで同じ 1 つになる。
 */

const { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } = require("fs");
const path = require("path");
const { render } = require("./rbxmx");

const PLUGIN_NAME = "rosheet";
const DEFAULT_PLUGIN_FILE = `${PLUGIN_NAME}.rbxmx`;
const SOURCE_DIR = path.join(__dirname, "..", "plugin", "src");
const ENTRY = "init.server.luau";

function robloxStudioPluginsDir(env = process.env, platform = process.platform) {
	if (platform === "win32" && env.LOCALAPPDATA) return path.join(env.LOCALAPPDATA, "Roblox", "Plugins");
	if (platform === "darwin" && env.HOME) return path.join(env.HOME, "Documents", "Roblox", "Plugins");
	return null;
}

function moduleChildren() {
	const children = [];

	for (const file of readdirSync(SOURCE_DIR).sort()) {
		if (file === ENTRY || !file.endsWith(".luau")) continue;
		children.push({
			className: "ModuleScript",
			name: path.basename(file, ".luau"),
			source: readFileSync(path.join(SOURCE_DIR, file), "utf8"),
		});
	}

	return children;
}

function buildPlugin() {
	if (!existsSync(path.join(SOURCE_DIR, ENTRY))) throw new Error(`The plugin source is missing: ${path.join(SOURCE_DIR, ENTRY)}`);

	return render({
		className: "Script",
		name: PLUGIN_NAME,
		source: readFileSync(path.join(SOURCE_DIR, ENTRY), "utf8"),
		children: moduleChildren(),
	});
}

function writePlugin(options = {}) {
	const cwd = options.cwd ?? process.cwd();
	const pluginsDir = robloxStudioPluginsDir();

	const target =
		options.output !== null && options.output !== undefined
			? path.resolve(cwd, options.output)
			: pluginsDir === null
				? path.resolve(cwd, DEFAULT_PLUGIN_FILE)
				: path.join(pluginsDir, DEFAULT_PLUGIN_FILE);

	const dir = path.dirname(target);
	if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
	writeFileSync(target, buildPlugin(), "utf8");

	return { path: target, intoStudio: pluginsDir !== null && target.startsWith(pluginsDir) };
}

module.exports = { PLUGIN_NAME, DEFAULT_PLUGIN_FILE, SOURCE_DIR, robloxStudioPluginsDir, buildPlugin, writePlugin };
