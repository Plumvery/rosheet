/** rosheet.lock.json —— 出荷する値の pin。
 *
 * `pull` が常に head を焼くと、調整が終わったあとの Apply が次の pull でそのまま出荷される。
 * 出口を固定するのがこのファイルで、pin を上げるには git の diff = PR が要る。
 *
 * lock はハッシュではなくデータセットごと持つ:
 *
 * - rosheet を上げて codegen の出力が変わっても `check` が正しく回る。生成物のハッシュを
 *   持たせると、出力の書式が変わっただけで全部無効になり、再 pull まで CI が落ちる
 * - lock だけで生成物を作り直せる。おかげでネットワークが要るのは `update` の 1 歩だけで、
 *   `pull` / `check` / `import --local` は Open Cloud のキー無しで回る
 * - PR の diff に値の変更がそのまま出る
 *
 * 値は生成物と lock に二重に載るが、生成物は place が読む Luau、lock は CLI が読む JSON で
 * 役割が別。`check` が「lock から作り直したものと生成物が一致するか」を見るのでずれない。
 *
 * 並びは src/rows.js の列順（スキーマ順）に固定する。Apply の差分判定と同じ規則なので、
 * 同じ値なら同じバイトになり、差分が値の変更だけを映す。
 */

const { readFileSync, writeFileSync, existsSync } = require("node:fs");
const path = require("node:path");

const { normalizeSchema } = require("./schema");
const { normalizeDataset, orderDataset, serializeSheet } = require("./rows");

const LOCK_FILE = "rosheet.lock.json";
const LOCK_VERSION = 1;

class LockError extends Error {}

function lockPath(cwd = process.cwd()) {
	return path.join(cwd, LOCK_FILE);
}

/** 無ければ null。「lock が無ければ今までどおり head を焼く」を呼び手が選べるようにする */
function readLock(cwd = process.cwd()) {
	const file = lockPath(cwd);
	if (!existsSync(file)) return null;

	let raw;
	try {
		raw = JSON.parse(readFileSync(file, "utf8"));
	} catch (error) {
		throw new LockError(`${LOCK_FILE} is not readable as JSON: ${error.message}`);
	}
	if (raw === null || typeof raw !== "object" || Array.isArray(raw)) throw new LockError(`${LOCK_FILE}: not an object`);
	if (raw.version !== LOCK_VERSION) throw new LockError(`${LOCK_FILE}: unsupported version: ${raw.version}`);
	if (!Number.isInteger(raw.seq) || raw.seq < 0) throw new LockError(`${LOCK_FILE}: seq must be a commit number`);
	return raw;
}

function writeLock(cwd, lock) {
	writeFileSync(lockPath(cwd), `${JSON.stringify(lock, null, "\t")}\n`, "utf8");
	return lockPath(cwd);
}

/** DataStore から引いた 1 時点を lock の形にする。スキーマも一緒に載せるので、この 1 枚で
 * 生成物を作り直せる（CLI は Luau を評価しないので、スキーマの出所はここか DataStore だけ） */
function buildLock({ schema, dataset, commit, tag = null }) {
	return {
		version: LOCK_VERSION,
		tag,
		seq: commit.seq,
		at: commit.at ?? null,
		by: commit.by ?? null,
		note: commit.note ?? "",
		schema,
		sheets: orderDataset(schema, dataset),
	};
}

/** lock を検証済みのスキーマとデータセットに開く。無ければ null。手で直した lock はここで落ちる */
function openLock(cwd = process.cwd()) {
	const lock = readLock(cwd);
	if (lock === null) return null;

	let schema;
	try {
		schema = normalizeSchema(lock.schema);
	} catch (error) {
		throw new LockError(`${LOCK_FILE}: schema: ${error.message}`);
	}

	let dataset;
	try {
		dataset = normalizeDataset(schema, lock.sheets);
	} catch (error) {
		throw new LockError(`${LOCK_FILE}: ${error.message}`);
	}

	return { lock, schema, dataset };
}

/** pin が要るコマンド用。無ければ、次に打つ手まで書いて落とす */
function loadLock(cwd = process.cwd()) {
	const opened = openLock(cwd);
	if (opened === null)
		throw new LockError(`No ${LOCK_FILE}. Run 'rosheet update' once to pin the values this project ships`);
	return opened;
}

/** 生成物のヘッダに焼く出所。tag があれば添える */
function sourceLabel(lock) {
	return lock.tag === null || lock.tag === undefined ? `commit #${lock.seq}` : `commit #${lock.seq} (${lock.tag})`;
}

/** lock の値と、DataStore から引いた値の差。`status` が「pin から手で動かしたシート」を出す */
function modifiedSheets(schema, lockDataset, remoteDataset) {
	return schema.sheets
		.filter((sheet) => serializeSheet(sheet, lockDataset[sheet.name]) !== serializeSheet(sheet, remoteDataset[sheet.name]))
		.map((sheet) => sheet.name);
}

module.exports = {
	LOCK_FILE,
	LOCK_VERSION,
	LockError,
	lockPath,
	readLock,
	writeLock,
	buildLock,
	openLock,
	loadLock,
	sourceLabel,
	modifiedSheets,
};
