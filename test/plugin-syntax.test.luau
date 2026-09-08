--!strict
-- plugin/src と runtime の Luau が構文として通るかだけを見る。
-- Studio でしか実行できないので（DataStoreService・plugin・Instance が要る）、ここで見るのは
-- コンパイルが通ることまで。振る舞いは Studio で確かめる。

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local DIRECTORIES = { "plugin/src", "runtime", "example" }

local failures = 0
local checked = 0

for _, directory in DIRECTORIES do
	if not fs.isDir(directory) then
		continue
	end

	for _, name in fs.readDir(directory) do
		if not string.match(name, "%.luau$") then
			continue
		end

		local path = `{directory}/{name}`
		local ok, err = pcall(function()
			luau.load(fs.readFile(path), { debugName = path })
		end)

		checked += 1
		if ok then
			print(`ok    {path}`)
		else
			failures += 1
			print(`FAIL  {path}`)
			print(`      {err}`)
		end
	end
end

print(`\n{checked - failures}/{checked} compiled`)
if failures > 0 then
	process.exit(1)
end
