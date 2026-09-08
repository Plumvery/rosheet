/** Open Cloud v2 の DataStore クライアント。
 *
 * 必要な API キーのスコープ:
 *   読むだけ（pull / check）  universe-datastores.objects:read
 *   書く（push / revert）      universe-datastores.objects:update
 *
 * v1 ではなく v2 を使う。v1 は本文の content-md5 を要求するのに対し、v2 は素の JSON で済み、
 * 値が任意の JSON として往復する。
 */

const BASE = "https://apis.roblox.com/cloud/v2";
const RETRYABLE = new Set([429, 500, 502, 503, 504]);
const MAX_ATTEMPTS = 4;
const TIMEOUT_MS = 30_000;

class OpenCloudError extends Error {
	constructor(message, status) {
		super(message);
		this.status = status;
	}
}

function requireApiKey(env = process.env) {
	const key = env.ROSHEET_API_KEY ?? env.ROBLOX_API_KEY;
	if (key === undefined || key === "")
		throw new OpenCloudError("No Open Cloud API key. Pass ROSHEET_API_KEY in .env or the environment");
	return key;
}

function sleep(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

/** キーは URL のパスに入るので、`/` を含むキーはここに来る前に弾いておく（src/store.js の形の約束）。
 *
 * scope は v2 ではパスの `scopes/<scope>` で表す（省略すると global）。プラグイン側の
 * `GetDataStore(name, scope)` と同じキースペースを指すので、両方に同じ値を書けば揃う。
 */
function entryUrl(universe, datastore, key, scope) {
	if (key.includes("/")) throw new OpenCloudError(`A key cannot contain /: ${key}`);
	const dataStore = `${BASE}/universes/${universe}/data-stores/${encodeURIComponent(datastore)}`;
	const keyspace = scope === undefined || scope === null ? dataStore : `${dataStore}/scopes/${encodeURIComponent(scope)}`;
	return `${keyspace}/entries/${encodeURIComponent(key)}`;
}

async function request(url, init, apiKey) {
	let lastError = null;
	for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
		// 外部呼び出しは必ず自分で打ち切る。握られたまま無出力で止まるのが一番困る
		const response = await fetch(url, {
			...init,
			headers: { "x-api-key": apiKey, "content-type": "application/json", ...(init.headers ?? {}) },
			signal: AbortSignal.timeout(TIMEOUT_MS),
		}).catch((error) => {
			lastError = new OpenCloudError(`${init.method ?? "GET"} ${url}: ${error.message}`, null);
			return null;
		});

		if (response === null) {
			if (attempt === MAX_ATTEMPTS) throw lastError;
			await sleep(500 * 2 ** (attempt - 1));
			continue;
		}

		if (response.ok) return response.status === 204 ? null : response.json();
		if (response.status === 404) return undefined;

		const body = await response.text().catch(() => "");
		if (RETRYABLE.has(response.status) && attempt < MAX_ATTEMPTS) {
			await sleep(500 * 2 ** (attempt - 1));
			continue;
		}
		throw new OpenCloudError(`${init.method ?? "GET"} ${url} returned ${response.status}: ${body.slice(0, 400)}`, response.status);
	}
	throw lastError;
}

function createClient({ universe, datastore, scope, apiKey = requireApiKey() }) {
	if (universe === undefined) throw new OpenCloudError("project.universe is missing from rosheet.toml");

	return {
		label: scope === undefined || scope === null ? `DataStore "${datastore}"` : `DataStore "${datastore}" (${scope})`,

		/** 無いキーは null。値は必ず JSON 文字列として置いてあるので、ここで一段ほどく */
		async get(key) {
			const entry = await request(entryUrl(universe, datastore, key, scope), { method: "GET" }, apiKey);
			if (entry === undefined) return null;
			if (typeof entry.value !== "string")
				throw new OpenCloudError(`${key}: not a value rosheet wrote (not a JSON string)`, null);
			return JSON.parse(entry.value);
		},

		async set(key, value) {
			const url = `${entryUrl(universe, datastore, key, scope)}?allowMissing=true`;
			await request(url, { method: "PATCH", body: JSON.stringify({ value: JSON.stringify(value) }) }, apiKey);
		},
	};
}

module.exports = { OpenCloudError, createClient, requireApiKey, entryUrl, BASE };
