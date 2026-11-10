local StartArenaMatch = {
	PrimaryAlias = "/startMatch",
	SecondaryAlias = "/startArena",
}

function StartArenaMatch.Trigger(player, words)
	local arenaName = table.concat(words, " ", 2)
	if #arenaName >= 2 and string.sub(arenaName, 1, 1) == '"' and string.sub(arenaName, -1) == '"' then
		arenaName = string.sub(arenaName, 2, -2)
	end
	if arenaName == "" then
		warn("[DevCommandService] Usage: /startMatch <arena name>")
		return
	end
	local MatchService = require(script.Parent.Parent.Parent.MatchService)
	local success, message = MatchService.StartArenaMatch(arenaName)
	if success then
		print("[DevCommandService]", player.Name, message)
	else
		warn("[DevCommandService]", message)
	end
end

return StartArenaMatch
