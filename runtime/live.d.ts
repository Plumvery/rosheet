// 同梱値と、Studio の Apply で届いた値を繋ぐ（roblox-ts 用の型）。実体は同じディレクトリの live.luau。

/**
 * 同梱値を、Studio では Apply 済みの値に差し替えて返す。型は同梱値のまま。
 * 本番では ReplicatedStorage に RosheetLive が無いので、同梱値をそのまま返す。
 *
 * ```ts
 * import * as guns from "shared/config/generated/guns";
 * const Guns = bind(guns, "guns");
 * print(Guns.get("AK47")?.damage);
 * ```
 */
export declare function bind<T>(baked: T, sheetName: string): T;

/** Apply のたびに走らせたい処理があるときに使う。戻り値を呼ぶと購読を切る */
export declare function onApplied(callback: (seq: number) => void): () => void;

export declare const FOLDER_NAME: string;
