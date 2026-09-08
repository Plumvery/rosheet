/** Script / ModuleScript の木を .rbxmx（Roblox の XML モデル）として書き出す。
 *
 * .rbxm（バイナリ）ではなく XML にする。バイナリを書くには rbxm-parser とその native な lz4 が
 * 要るうえ、あれは Script.Source の非 ASCII を壊す。プラグインの UI には日本語のラベルが載るので、
 * その制約を持ち込まない。XML なら依存ゼロで、Studio の Plugins フォルダはそのまま読む。
 */

const HEADER =
	'<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">';

function escapeText(value) {
	return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/** CDATA の中に `]]>` があるとそこで閉じてしまうので、区切って繋ぎ直す */
function cdata(value) {
	return `<![CDATA[${value.split("]]>").join("]]]]><![CDATA[>")}]]>`;
}

function renderItem(node, state, depth) {
	const pad = "\t".repeat(depth);
	const referent = `RBX${state.next++}`;
	const lines = [
		`${pad}<Item class="${node.className}" referent="${referent}">`,
		`${pad}\t<Properties>`,
		`${pad}\t\t<string name="Name">${escapeText(node.name)}</string>`,
	];

	if (node.source !== undefined)
		lines.push(`${pad}\t\t<ProtectedString name="Source">${cdata(node.source)}</ProtectedString>`);

	lines.push(`${pad}\t</Properties>`);
	for (const child of node.children ?? []) lines.push(renderItem(child, state, depth + 1));
	lines.push(`${pad}</Item>`);
	return lines.join("\n");
}

function render(root) {
	return ['<?xml version="1.0" encoding="utf-8"?>', HEADER, renderItem(root, { next: 0 }, 1), "</roblox>", ""].join("\n");
}

module.exports = { render, cdata, escapeText };
