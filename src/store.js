/** DataStore に置く履歴の形。プラグイン（Luau）と CLI（JS）が両方これを実装する。
 *
 * 形の要点:
 *
 * - キーに `/` を入れない。Open Cloud v2 はキーを URL のパスに埋めるので、`/` を含むキーは
 *   エンコードの問題を持ち込む。区切りは `.`（キー名は 50 文字まで）
 * - 値は必ず JSON 文字列として置く。Luau のテーブルをそのまま置くと、Open Cloud がそれを
 *   どんな JSON に落とすかに全部が乗る（空のテーブルが配列と辞書のどちらになるか、が典型）。
 *   文字列にしておけば、符号化するのは常に HttpService:JSONEncode の側だけになる
 *   （実測: Studio の JSONEncode は空テーブルを `[]` にする）
 * - 履歴は前へ進むだけ。巻き戻しは「昔の commit と同じ中身の新しい commit を積む」で表す。
 *   過去の commit を書き換えないので、巻き戻した後にさらに戻ることもできる
 * - DataStore 組み込みの versioning は使わない。あれはキーごとに UTC 1 時間で 1 版しか作らず、
 *   同じ時間内の後続の書き込みは前を恒久的に上書きするため、Apply の履歴には使えない
 */

const HEAD_KEY = "head";
const LOG_KEY = "log";
/** tag は 1 キーにまとめて置く。`tag.<name>` を 1 タグ 1 キーにすると、キーが 50 文字までで
 * `/` も使えないので `release/1.0` のような名前が入らない。まとめておけばプラグインも 1 回
 * 読むだけで「head は pin より何 commit 先か」を出せる */
const TAGS_KEY = "tags";
/** プラグインが place のスキーマモジュールを require して置き直す。CLI は Luau を評価しないので、
 * CLI から見えるスキーマの正はこのキー（CI 用にローカルへ保存もできる） */
const SCHEMA_KEY = "schema";
const SEQ_DIGITS = 6;
const MAX_KEY_LENGTH = 50;
/** log に残す件数。1 キー 4MB なので、要約だけならこの件数で収まる */
const LOG_LIMIT = 200;
/** tag に残す件数。log と同じ理由で切る */
const TAG_LIMIT = 200;
const MAX_TAG_NAME = 64;
// 生成物のヘッダと rosheet.lock.json に載るので、引用の要らない字だけにする
const TAG_NAME = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;

function formatSeq(seq) {
	return String(seq).padStart(SEQ_DIGITS, "0");
}

function commitKey(seq) {
	return `commit.${formatSeq(seq)}`;
}

function blobKey(seq, sheetName) {
	return `blob.${formatSeq(seq)}.${sheetName}`;
}

/** シート名の上限。blob キーが 50 文字に収まる長さから決まる */
const MAX_SHEET_NAME = MAX_KEY_LENGTH - blobKey(0, "").length;

function checkSheetNames(schema) {
	for (const sheet of schema.sheets)
		if (sheet.name.length > MAX_SHEET_NAME)
			throw new Error(`Sheet name is too long (the DataStore key would exceed ${MAX_KEY_LENGTH} characters): ${sheet.name}`);
}

function emptyHead() {
	return { seq: 0 };
}

/** seq 0 は「まだ一度も Apply していない」を表す番兵で、実体の commit を持たない */
function emptyCommit() {
	return { seq: 0, parent: null, at: null, by: null, note: "", sheets: {} };
}

/** 変わったシートだけ新しい blob を作り、変わらないシートは前の commit の blob を指し直す */
function planCommit(schema, previous, previousSerialized, nextSerialized, meta) {
	const seq = previous.seq + 1;
	const sheets = {};
	const blobs = [];
	const changed = [];

	for (const sheet of schema.sheets) {
		const before = previousSerialized[sheet.name];
		const after = nextSerialized[sheet.name];
		if (before === after && previous.sheets[sheet.name] !== undefined) {
			sheets[sheet.name] = previous.sheets[sheet.name];
			continue;
		}
		sheets[sheet.name] = seq;
		blobs.push({ key: blobKey(seq, sheet.name), value: after });
		changed.push(sheet.name);
	}

	const commit = {
		seq,
		parent: previous.seq === 0 ? null : previous.seq,
		at: meta.at,
		by: meta.by,
		note: meta.note ?? "",
		sheets,
	};

	return { commit, blobs, changed };
}

/** 巻き戻し: 昔の commit の中身をそのまま指す新しい commit。blob は既にあるので書かない */
function planRevert(previous, target, meta) {
	return {
		commit: {
			seq: previous.seq + 1,
			parent: previous.seq === 0 ? null : previous.seq,
			at: meta.at,
			by: meta.by,
			note: meta.note ?? `revert to #${target.seq}`,
			sheets: { ...target.sheets },
			revertOf: target.seq,
		},
		blobs: [],
		changed: Object.keys(target.sheets),
	};
}

function checkTagName(name) {
	if (typeof name !== "string" || name.length > MAX_TAG_NAME || !TAG_NAME.test(name))
		throw new Error(
			`A tag name must start with a letter or digit and use only [A-Za-z0-9._/-], up to ${MAX_TAG_NAME} characters: ${name}`,
		);
	return name;
}

function emptyTags() {
	return { entries: [] };
}

function findTag(tags, name) {
	return (tags.entries ?? []).find((entry) => entry.name === name);
}

/** pin の基準にする tag。作った順ではなく指している commit が一番新しいものを採る
 * （古い commit に後から名前を付けても「出荷済みの先端」は動かない）。
 *
 * プラグインが同じ規則をステータス行（`#45 · 3 ahead of v0.3.0`）で実装する。このファイルは
 * 保存先の形の正なので、Luau 側と揃える規則はここに置く */
function latestTag(tags) {
	return (tags.entries ?? []).reduce((best, entry) => (best === undefined || entry.seq > best.seq ? entry : best), undefined);
}

/** 同じ名前は既定で拒む。tag は「あの時の値」を指す名前なので、黙って動くと意味が無くなる */
function putTag(tags, entry, options = {}) {
	const entries = tags.entries ?? [];
	const existing = findTag(tags, entry.name);
	if (existing !== undefined && options.force !== true)
		throw new Error(`tag ${entry.name} already points at #${existing.seq}. Pass --force to move it`);
	const rest = entries.filter((other) => other.name !== entry.name);
	return { entries: [entry, ...rest].slice(0, TAG_LIMIT) };
}

function appendLog(log, commit, changed) {
	const entries = [
		{ seq: commit.seq, at: commit.at, by: commit.by, note: commit.note, changed, revertOf: commit.revertOf ?? null },
		...(log.entries ?? []),
	];
	return { entries: entries.slice(0, LOG_LIMIT) };
}

module.exports = {
	HEAD_KEY,
	LOG_KEY,
	SCHEMA_KEY,
	TAGS_KEY,
	LOG_LIMIT,
	TAG_LIMIT,
	MAX_KEY_LENGTH,
	MAX_SHEET_NAME,
	MAX_TAG_NAME,
	formatSeq,
	commitKey,
	blobKey,
	checkSheetNames,
	checkTagName,
	emptyHead,
	emptyCommit,
	emptyTags,
	findTag,
	latestTag,
	putTag,
	planCommit,
	planRevert,
	appendLog,
};
