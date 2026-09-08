// rosheet の入口（roblox-ts 用の型）。実体は同じディレクトリの init.luau。
//
// ファイル名が init.d.ts ではなく index.d.ts なのは、roblox-ts が `index.ts` を `init.luau`
// として出すため。フォルダごと import したときに、この型が当たる:
//
//     import { bind, defineSchema } from "shared/rosheet";
//
// 1 本ずつ import してもよい（"shared/rosheet/schema" / "shared/rosheet/live"）。この
// ディレクトリを利用側の src/ へ置くには `npx rosheet runtime` を使う。

export * from "./schema";
export * from "./live";
