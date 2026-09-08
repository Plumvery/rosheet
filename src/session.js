/** DataStore から現在の値・履歴を読み、新しい commit を積む。CLI 側の入口。
 *
 * プラグイン（Luau）も同じ形を実装するが、コードは共有できない。形の正は src/store.js の
 * コメントで、両方がそれを実装しているかは docs/storage.md の表で突き合わせる。
 */

const { normalizeSchema } = require("./schema");
const { normalizeDataset, serializeSheet, emptyDataset } = require("./rows");
const store = require("./store");

async function readSchema(client) {
	const raw = await client.get(store.SCHEMA_KEY);
	if (raw === null)
		throw new Error(
			`DataStore にスキーマが無い。Studio で place を開き、rosheet プラグインを一度起動してスキーマを置く`,
		);
	const schema = normalizeSchema(raw);
	store.checkSheetNames(schema);
	return schema;
}

async function readHead(client) {
	return (await client.get(store.HEAD_KEY)) ?? store.emptyHead();
}

async function readCommit(client, seq) {
	if (seq === 0) return store.emptyCommit();
	const commit = await client.get(store.commitKey(seq));
	if (commit === null) throw new Error(`commit #${seq} が DataStore に無い`);
	return commit;
}

/** commit が指す blob を集めてデータセットに戻す。シートは並列に引いてよい（読みは互いに独立） */
async function readDataset(client, schema, commit) {
	if (commit.seq === 0) return emptyDataset(schema);

	const entries = await Promise.all(
		schema.sheets.map(async (sheet) => {
			const blobSeq = commit.sheets[sheet.name];
			// commit より後にスキーマへ足されたシートは、その commit には入っていない
			if (blobSeq === undefined) return [sheet.name, undefined];
			const value = await client.get(store.blobKey(blobSeq, sheet.name));
			if (value === null) throw new Error(`${store.blobKey(blobSeq, sheet.name)} が DataStore に無い`);
			return [sheet.name, value];
		}),
	);

	return normalizeDataset(schema, Object.fromEntries(entries.filter(([, value]) => value !== undefined)));
}

async function readCurrent(client) {
	const schema = await readSchema(client);
	const head = await readHead(client);
	const commit = await readCommit(client, head.seq);
	const dataset = await readDataset(client, schema, commit);
	return { schema, head, commit, dataset };
}

function serializeAll(schema, dataset) {
	return Object.fromEntries(schema.sheets.map((sheet) => [sheet.name, serializeSheet(sheet, dataset[sheet.name])]));
}

/** 新しい commit を積んで head を進める。head は最後に動かす（途中で落ちても現在値は壊れない） */
async function commitDataset(client, { schema, commit: previous, dataset: previousDataset }, nextDataset, meta) {
	const plan = store.planCommit(
		schema,
		previous,
		serializeAll(schema, previousDataset),
		serializeAll(schema, normalizeDataset(schema, nextDataset)),
		meta,
	);
	if (plan.changed.length === 0) return { changed: [], commit: previous };
	return writePlan(client, plan);
}

async function writePlan(client, plan) {
	for (const blob of plan.blobs) await client.set(blob.key, JSON.parse(blob.value));
	await client.set(store.commitKey(plan.commit.seq), plan.commit);
	await client.set(store.HEAD_KEY, { seq: plan.commit.seq });

	const log = (await client.get(store.LOG_KEY)) ?? { entries: [] };
	await client.set(store.LOG_KEY, store.appendLog(log, plan.commit, plan.changed));

	return { changed: plan.changed, commit: plan.commit };
}

async function revert(client, current, targetSeq, meta) {
	const target = await readCommit(client, targetSeq);
	if (target.seq === 0) throw new Error("commit #0 は番兵なので戻れない");
	return writePlan(client, store.planRevert(current.commit, target, meta));
}

async function readLog(client) {
	return (await client.get(store.LOG_KEY)) ?? { entries: [] };
}

module.exports = { readSchema, readHead, readCommit, readDataset, readCurrent, commitDataset, revert, readLog, serializeAll };
