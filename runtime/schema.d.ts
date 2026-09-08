// rosheet のスキーマ定義（roblox-ts 用の型）。実体は同じディレクトリの schema.luau。

export type ColumnType = "string" | "text" | "number" | "integer" | "boolean" | "enum" | "asset" | "color";

export interface ColumnOptions {
	readonly readonly?: boolean;
	readonly default?: string | number | boolean;
	readonly description?: string;
	readonly values?: readonly string[];
	readonly min?: number;
	readonly max?: number;
}

export interface Column {
	readonly name: string;
	readonly type: ColumnType;
	readonly readonly?: boolean;
	readonly default?: string | number | boolean;
	readonly description?: string;
	readonly values?: readonly string[];
	readonly min?: number;
	readonly max?: number;
}

export interface SheetOptions {
	readonly kind?: "table" | "scalars";
	/** 行を引くキーになる列。string の列だけ指定できる */
	readonly key?: string;
	/** "fixed" にすると Studio から行を足せなくなる */
	readonly rows?: "open" | "fixed";
	readonly description?: string;
	readonly columns: readonly Column[];
}

export interface Sheet {
	readonly name: string;
	readonly columns: readonly Column[];
}

export interface DefinitionOptions {
	/** プラグインが読み書きする DataStore 名（既定: "rosheet"） */
	readonly datastore?: string;
	readonly scope?: string;
	/** ここに無い place では、プラグインが読み取り専用になる（宣言しなければどの place でも書ける）。
	 * 事故を止めるためのもので、権限の境界ではない —— DataStore の権限は universe 単位 */
	readonly writablePlaces?: readonly number[];
}

export interface Definition {
	readonly sheets: readonly Sheet[];
	readonly datastore?: string;
	readonly scope?: string;
	readonly writablePlaces?: readonly number[];
}

/** ランタイムの版。プラグインが「place に置かれている版」と「Studio が評価している版」を
 * 突き合わせ、ズレていたら読み取り専用になる（Studio の require キャッシュは恒久的なので、
 * ランタイムを上げた直後の 1 セッションは古い defineSchema が評価され続ける） */
export declare const VERSION: number;

export declare function column(name: string, columnType: ColumnType, options?: ColumnOptions): Column;
export declare function sheet(name: string, options: SheetOptions): Sheet;
export declare function defineSchema(sheets: readonly Sheet[], options?: DefinitionOptions): Definition;
