--!strict
-- Resets the caller's profile and future purchase allowances, then disconnects them to reload defaults.

--// Modules
local PlayerDataService = require(game:GetService("ServerScriptService").Services.PlayerDataService)

--// Types
export type ResetPlayerData = {
	PrimaryAlias: string,
	SecondaryAlias: string,
	Trigger: (player: Player, words: { string }) -> (),
}

--// Command
local Command = {
	PrimaryAlias = "/resetData",
	SecondaryAlias = "/resetPlayerData",
} :: ResetPlayerData

--// APIs
function Command.Trigger(player, words)
	if #words ~= 1 then
		warn("[DevCommandService] Usage: /resetData (resets only your own profile)")
		return
	end
	local success, reason = PlayerDataService.ResetPlayerData(player)
	if success then
		print("[DevCommandService] Reset player data for", player.Name, player.UserId)
	else
		warn("[DevCommandService] Player data reset failed:", reason)
	end
end

return Command
