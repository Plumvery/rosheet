--!strict
-- 共有下書き。Apply していない編集を、チームの全員で 1 つ持つ。
--
-- 下書きを「データセット丸ごと」ではなく **base からのセル単位の差分** として持つ。理由は 3 つ:
--
-- 1. MemoryStore は 1 項目 30KB までしか載らない（実測: 30720 は通り、32768 は
--    `ItemValueSizeTooLarge`）。シートの値を丸ごと置くと、少し大きい表で即あふれる。差分なら
--    普通の編集セッションで数十セル、桁が 2 つ違う
-- 2. シート丸ごとの置き換えだと、同じシートを 2 人で触った時点で後から書いた方が相手を消す。
--    セル単位なら、違うセルを触っているかぎり誰も消えない
-- 3. **誰がどのセルを触ったかを、差分がそのまま持つ。** Apply の前に「他の人の編集も一緒に
--    出荷されます」と出すのに要る情報が、別の台帳を持たなくても揃う
--
-- 行の見分け方は `Rows.countRows` と同じ規則にする —— key があれば key の値、無ければ位置。
-- 規則を 2 つ持つと、履歴の要約と下書きの併合で違う行を同じ行だと言い出す。key の無いシートで
-- 位置がずれる弱さもそのまま引き継ぐ（`Draft.sharable` がそれを名指しする）。
--
-- Roblox の API に触らない。Store も Session も require しない。おかげで併合の規則を Lune の
-- テストから回せる（`Session` を保存先から切り離してあるのと同じ理由）。

local Schema = require(script.Parent.Schema)
local Rows = require(script.Parent.Rows)

local Draft = {}

-- scalars には行が無い。1 枚のテーブルなので、行の識別子は 1 つで足りる
local SCALAR_ROW = ""

export type Cell = {
	value: any,
	by: string,
	at: string,
}

export type SheetDelta = {
	-- 行の識別子 → 列名 → セル
	cells: { [string]: { [string]: Cell } },
	-- 足した行。値は列名 → 値（作者は `by`）
	added: { [string]: { row: { [string]: any }, by: string, at: string } },
	-- 消した行
	removed: { [string]: { by: string, at: string } },
}

export type Delta = {
	-- どの commit を土台にした下書きか。base が動いたら下書きは載せ替えられない
	base: number,
	sheets: { [string]: SheetDelta },
}

function Draft.empty(base: number): Delta
	return { base = base, sheets = {} }
end

--[[
	その行の識別子。

	key があれば key の値、無ければ位置。`Rows.countRows` が履歴の要約で使っているのと同じ規則で、
	同じ弱さを持つ —— key の無いシートで誰かが行を足すと、それより下のセルの識別子がずれる。
]]
function Draft.rowId(sheet: Schema.Sheet, row: { [string]: any }?, index: number): string
	if sheet.kind == "scalars" then
		return SCALAR_ROW
	end
	local key = sheet.key
	if key == nil or row == nil then
		return tostring(index)
	end
	local value = row[key]
	return if type(value) == "string" then value else tostring(index)
end

--[[
	そのシートの下書きを他の人と共有してよいか。

	key の無い表は、位置でしか行を見分けられない。1 人で編集しているうちは位置は動かないが、
	共有すると「相手が上の行を足した瞬間、自分が触っていたセルの識別子が別の行を指す」ことが
	起きる。黙って壊すより共有しない方がましなので、ここで分けて呼び手に言わせる。

	scalars と key のある表、それに行の増減が起きない `rows = "fixed"` は共有してよい。
]]
function Draft.sharable(sheet: Schema.Sheet): boolean
	return sheet.kind == "scalars" or sheet.key ~= nil or sheet.rows == "fixed"
end

local function sheetDelta(delta: Delta, sheetName: string): SheetDelta
	local existing = delta.sheets[sheetName]
	if existing ~= nil then
		return existing
	end
	local created: SheetDelta = { cells = {}, added = {}, removed = {} }
	delta.sheets[sheetName] = created
	return created
end

function Draft.setCell(delta: Delta, sheetName: string, rowId: string, column: string, value: any, by: string, at: string)
	local sheet = sheetDelta(delta, sheetName)

	-- まだ Apply していない行への編集は、その行の値そのものを書き換える。cells に積むと、
	-- 行を足した人と直した人が別々に記録され、`added` の中身と食い違う
	local added = sheet.added[rowId]
	if added ~= nil then
		added.row[column] = value
		return
	end

	local row = sheet.cells[rowId]
	if row == nil then
		row = {}
		sheet.cells[rowId] = row
	end
	local cells = row :: { [string]: Cell }
	cells[column] = { value = value, by = by, at = at }
end

function Draft.addRow(delta: Delta, sheetName: string, rowId: string, row: { [string]: any }, by: string, at: string)
	local sheet = sheetDelta(delta, sheetName)
	sheet.removed[rowId] = nil
	sheet.added[rowId] = { row = row, by = by, at = at }
end

function Draft.removeRow(delta: Delta, sheetName: string, rowId: string, by: string, at: string)
	local sheet = sheetDelta(delta, sheetName)

	-- まだ Apply していない行を消すなら、記録ごと捨てる。`removed` に積むと、保存先に無い行を
	-- 「消した」と言い続けることになる
	if sheet.added[rowId] ~= nil then
		sheet.added[rowId] = nil
		sheet.cells[rowId] = nil
		return
	end

	sheet.cells[rowId] = nil
	sheet.removed[rowId] = { by = by, at = at }
end

--[[ 何も触っていない下書きか。空なら保存先へ置かないし、ベルも鳴らさない ]]
function Draft.isEmpty(delta: Delta): boolean
	for _, sheet in delta.sheets do
		if next(sheet.cells) ~= nil or next(sheet.added) ~= nil or next(sheet.removed) ~= nil then
			return false
		end
	end
	return true
end

--[[ 触ったセルの数。ステータス行と確認ダイアログに出す ]]
function Draft.count(delta: Delta): number
	local total = 0
	for _, sheet in delta.sheets do
		for _, row in sheet.cells do
			for _ in row do
				total += 1
			end
		end
		for _ in sheet.added do
			total += 1
		end
		for _ in sheet.removed do
			total += 1
		end
	end
	return total
end

--[[
	自分以外に誰が触っているか。Apply の前に出す確認ダイアログの中身。

	名前だけでなく、その人が触ったセルの数も返す。「誰かが触っています」だけだと、押してよいのか
	判断できない —— 1 セルなのか 200 セルなのかで意味が違う。
]]
export type Contributor = { by: string, cells: number }

function Draft.otherAuthors(delta: Delta, me: string): { Contributor }
	local counts: { [string]: number } = {}

	local function add(by: string)
		if by ~= me then
			counts[by] = (counts[by] or 0) + 1
		end
	end

	for _, sheet in delta.sheets do
		for _, row in sheet.cells do
			for _, cell in row do
				add(cell.by)
			end
		end
		for _, entry in sheet.added do
			add(entry.by)
		end
		for _, entry in sheet.removed do
			add(entry.by)
		end
	end

	local authors: { Contributor } = {}
	for by, cells in counts do
		table.insert(authors, { by = by, cells = cells })
	end
	-- 触った数の多い順。名前順だと、いちばん影響の大きい人が下に埋まる
	table.sort(authors, function(a, b)
		if a.cells == b.cells then
			return a.by < b.by
		end
		return a.cells > b.cells
	end)
	return authors
end

--[[
	base のデータセットに下書きを載せて、画面に出すデータセットを作る。

	base は触らない（`Rows.cloneDataset` した写しに書く）。base をそのまま書き換えると、
	「保存先の値」と「下書きの値」が同じテーブルを指し、黄色の差分表示が出なくなる。
]]
function Draft.apply(schema: Schema.Normalized, base: { [string]: Rows.SheetValue }, delta: Delta): { [string]: Rows.SheetValue }
	local dataset = Rows.cloneDataset(schema, base)

	for _, sheet in schema.sheets do
		local sheetChanges = delta.sheets[sheet.name]
		if sheetChanges == nil then
			continue
		end

		if sheet.kind == "scalars" then
			local values = dataset[sheet.name] :: { [string]: any }
			local row = sheetChanges.cells[SCALAR_ROW]
			if row ~= nil then
				for column, cell in row do
					values[column] = cell.value
				end
			end
			continue
		end

		local rows = dataset[sheet.name] :: { { [string]: any } }

		-- 消す方を先にやる。足してから消すと、足した行の位置が消した分だけずれる
		if next(sheetChanges.removed) ~= nil then
			local kept: { { [string]: any } } = {}
			for index, row in rows do
				if sheetChanges.removed[Draft.rowId(sheet, row, index)] == nil then
					table.insert(kept, row)
				end
			end
			rows = kept
			dataset[sheet.name] = rows
		end

		for index, row in rows do
			local changes = sheetChanges.cells[Draft.rowId(sheet, row, index)]
			if changes ~= nil then
				for column, cell in changes do
					row[column] = cell.value
				end
			end
		end

		-- 足した行は末尾へ。識別子の順に入れるのは、誰の Studio でも同じ並びにするため
		local ids: { string } = {}
		for id in sheetChanges.added do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			table.insert(rows, table.clone((sheetChanges.added[id] :: any).row))
		end
	end

	return dataset
end

--[[
	2 つの下書きを併合する。ポーリングで拾った相手の下書きを、自分の下書きへ載せるのに使う。

	同じセルを 2 人が触っていたら `at` の新しい方が勝つ。時計は Studio ごとにずれうるので、
	これは「正しい順序」ではなく「決まった順序」——— 同じ 2 つの下書きを誰が併合しても同じ結果に
	なることだけを保証する。ずれても消えるのは同じセルへの後追いの編集 1 つで、他人の別のセルは
	消えない。ここを「後から届いた方が勝つ」にすると、ポーリングの順番で結果が変わって再現しない。

	base が違う下書きは併合しない。土台が違えば行の識別子の指す先が違うので、混ぜると別の行の
	値を書くことになる。呼び手は base の新しい方を採って作り直す。
]]
function Draft.merge(mine: Delta, theirs: Delta): Delta
	if mine.base ~= theirs.base then
		return if theirs.base > mine.base then theirs else mine
	end

	local merged: Delta = { base = mine.base, sheets = {} }

	local function take(source: Delta)
		for sheetName, sheet in source.sheets do
			local into = sheetDelta(merged, sheetName)

			for rowId, row in sheet.cells do
				local target = into.cells[rowId]
				if target == nil then
					target = {}
					into.cells[rowId] = target
				end
				local cells = target :: { [string]: Cell }
				for column, cell in row do
					local existing = cells[column]
					if existing == nil or cell.at > existing.at then
						cells[column] = cell
					end
				end
			end

			for rowId, entry in sheet.added do
				local existing = into.added[rowId]
				if existing == nil or entry.at > existing.at then
					into.added[rowId] = entry
				end
			end

			for rowId, entry in sheet.removed do
				local existing = into.removed[rowId]
				if existing == nil or entry.at > existing.at then
					into.removed[rowId] = entry
				end
			end
		end
	end

	take(mine)
	take(theirs)

	-- 消したあとに足し直された行は、足した方を採る。順に見ているだけだと、両方に残る
	for _, sheet in merged.sheets do
		for rowId, added in sheet.added do
			local removed = sheet.removed[rowId]
			if removed ~= nil and added.at >= removed.at then
				sheet.removed[rowId] = nil
			end
		end
	end

	return merged
end

--[[
	保存先へ置ける形か。MemoryStore は 1 項目 30KB までなので、大きくなった下書きは載らない。

	載らないときに黙って落とすと、共有が止まったことに誰も気づかない。呼び手が「今この下書きは
	共有されていない」と出せるよう、判定だけ返す（符号化はここではやらない —— この module は
	Roblox の API に触らない）。
]]
Draft.MEMORY_STORE_LIMIT = 30 * 1024

function Draft.fitsInMemoryStore(encodedLength: number): boolean
	return encodedLength <= Draft.MEMORY_STORE_LIMIT
end

Draft.SCALAR_ROW = SCALAR_ROW

return Draft
