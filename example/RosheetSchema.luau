--!strict
-- rosheet のスキーマの例。この ModuleScript を place の ServerStorage に
-- `RosheetSchema` という名前で置くと、プラグインがこれを読んで表を出す。
--
-- ReplicatedStorage には置かない。本番のクライアントにまで配信されるため。

local rosheet = require(script.Parent.rosheet.schema)

return rosheet.defineSchema({
	rosheet.sheet("guns", {
		key = "id",
		description = "銃のパラメータ",
		columns = {
			rosheet.column("id", "string", { readonly = true, description = "コードから引くキー" }),
			rosheet.column("name", "string", { description = "画面に出る名前" }),
			rosheet.column("damage", "number", { default = 10, min = 0, description = "1 発のダメージ" }),
			rosheet.column("fireRate", "number", { default = 0.2, min = 0.01, description = "発射間隔（秒）" }),
			rosheet.column("rarity", "enum", { values = { "Common", "Rare", "Epic", "Legendary" } }),
			rosheet.column("icon", "asset", { description = "空のままでもよい" }),
			rosheet.column("enabled", "boolean", { default = true }),
		},
	}),

	rosheet.sheet("rarities", {
		key = "id",
		description = "レア度ごとの表示色。guns の rarity 列と対にする",
		-- 行を増やすと guns の enum と食い違うので、増減はコード側の宣言でだけ行う
		rows = "fixed",
		columns = {
			rosheet.column("id", "string", { readonly = true }),
			rosheet.column("color", "color", { default = "#FFFFFF" }),
		},
	}),

	rosheet.sheet("round", {
		kind = "scalars",
		description = "ラウンド進行の定数",
		columns = {
			rosheet.column("SECONDS", "integer", { default = 180, min = 30, description = "1 ラウンドの長さ" }),
			rosheet.column("MIN_PLAYERS", "integer", { default = 2, min = 1 }),
			rosheet.column("INTERMISSION", "integer", { default = 15, min = 0 }),
			rosheet.column("LABEL", "string", { default = "ラウンド" }),
		},
	}),
})
