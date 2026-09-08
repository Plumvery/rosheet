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

export interface Definition {
	readonly sheets: readonly Sheet[];
}

export declare function column(name: string, columnType: ColumnType, options?: ColumnOptions): Column;
export declare function sheet(name: string, options: SheetOptions): Sheet;
export declare function defineSchema(sheets: readonly Sheet[]): Definition;
