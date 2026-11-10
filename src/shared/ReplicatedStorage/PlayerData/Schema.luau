--!strict
-- Defines readable player-data groups, persistent defaults and client-local write permissions.

--// Services
local RunService = game:GetService("RunService")

--// Types
export type Field = {
	-- Readable group folder that stores this logical field.
	Group: string,
	-- Enforced scalar kind for original fixed fields and inventory strings; nil preserves flexible scalar writes.
	Kind: string?,
	-- Profile or Session persistence policy; undeclared fields retain legacy routing.
	Persistence: string?,
	-- Public values replicate; Server values live only in ServerStorage.
	Visibility: string?,
}
export type Schema = {
	-- Default persistent profile values before saved data is loaded.
	DefaultAttributes: { [string]: boolean | number | string },
	-- Default persistent player settings.
	DefaultSettings: { [string]: boolean | number | string },
	-- Initial transient player values for the current server session.
	SessionAttributes: { [string]: boolean | number | string },
	-- Group routing and optional write-kind contracts indexed by logical player-data key.
	Fields: { [string]: Field },
	-- Ordered readable group folder names.
	Groups: { string },
	-- Resolves a declared key to its group, or Dynamic for an unlisted key.
	Group: (string) -> string,
	-- Allowed client-local override keys mapped to their scalar type names.
	LocalKeys: { [string]: string },
	-- Authorized setting keys mapped to their scalar type names.
	Settings: { [string]: string },
}

--// Properties
local Fields: { [string]: Field } = {}
local Groups: { string } = {}

--// Controller
local Schema: Schema = {
	DefaultAttributes = {
		-- Progression
		Level = 1,
		Experience = 0,
		-- Valute
		BagScore = 0,
		Coins = 0,
		Coins_Day = 0,
		Coins_Week = 0,
		Coins_Month = 0,
		-- Stats
		Kills = 0,
		Kills_Day = 0,
		Kills_Week = 0,
		Kills_Month = 0,
		Wins = 0,
		Wins_Day = 0,
		Wins_Week = 0,
		Wins_Month = 0,
		Deaths = 0,
		-- Ranking
		--RankPoints = 0,
		Trophies = 0,
		PeakTrophies = 0,
		-- Nuove stats aggiunte
		GamesPlayed = 0,
		PreferredWeapon = "Slap",
		PreferredAbility = "Dash",
		-- Varie
		Playtime = 0,
		LastDay = "",
		LastWeek = "",
		LastMonth = "",
		-- Inventario
		EquippedWeaponName = "Slap",
		EquippedBaseWeapon = "Slap",
		OwnedWeapons = "Slap,Bat,Chicken,Hammer,Stick",
		EquippedAbility = "Dash",
		OwnedAbilities = "Dash",
		OwnedChests = "{}",
		CarriedChests = "",
		RedeemedCodes = "",

		-- Social
		EarlyRewardClaimed = false,
		GroupRewardClaimed = false,

		-- Tutorial (TutorialService): true once the new-player tutorial was finished or skipped.
		TutorialCompleted = false,

		-- Daily rewards (DailyRewardService): days claimed in the current cycle (0..14) and the os.time() of the last claim.
		DailyRewardDay = 0,
		DailyRewardLastClaim = 0,

		-- Has x2 coin
		Has2xCoins = false,
		Has2xCoinsBuff = false,
		x2CoinBuffExpiredOn = 0,
		x2CoinBuffOfflineTimestamp = -1, -- to compensate when offline

		-- Robux shop
		FirstTimeCoinPack = "",
		SimpleWeaponPackPurchases = "{}", -- RotationKey + Counts; saved by the ordinary profile lifecycle.
		OneTimePasses = "", -- Comma-separated config keys of claimed passes.
		OneTimePacks = "", -- Comma-separated pack keys, LimitedItem rotation keys and LimitedItemReceipt:<PurchaseId>.
		ProcessedGiftReceipts = "{}", -- Saved atomically with gift rewards; JSON receipt-ID dictionary.
		PurchaseAllowanceGeneration = "", -- Empty preserves legacy quotas; explicit reset creates a fresh allowance namespace.
		-- [PurchaseId] = { ProductId, Group, Weapon, Claimed }; preserves pending reveals/replays.
		-- Purchase histories are loaded into __Shop, never replicated as attributes.

		DailyWins = 0,
		DailyWinsTimestamp = 0, -- Start of the current UTC calendar day.
		DailyWinsClaimed = false, -- Saved together with the granted chest inventory.
	},
	DefaultSettings = {
		Setting_SFXVolume = 50,
		Setting_MusicVolume = 50,
		Setting_PerformanceMode = false,
		Setting_AutoAim = true,
		--IsAFK = false,
		Hardware = "Mobile",
	},
	SessionAttributes = {
		IsOnArena = false,
		Lives = 3,
		IsAFK = RunService:IsStudio(),

		-- Stats da mostrare sul MatchSummary
		MatchKills = 0,
		MatchHits = 0,
		MatchStuds = 0,

		GlobalRank = 0, -- 0 = unranked / snapshot not loaded yet
		GlobalRankOverflow = false, -- deeper than the scanned depth → UI shows "100,000+"
		SnapshotRank = 0, -- player's row index in the loaded snapshot (0 = not in list)
		MatchId = 0, -- match this player was teleported into
		TrophyMatchId = 0, -- last match whose trophy result was applied (idempotency guard)
		MatchTrophyDelta = 0, -- +/- of the last match (popup / future MatchSummary)
	},
	Fields = Fields,
	Groups = Groups,
	Group = function(key: string): string
		local field = Fields[key]
		return if field then field.Group else "Dynamic"
	end,
	Settings = {
		Setting_SFXVolume = "number",
		Setting_MusicVolume = "number",
		Setting_PerformanceMode = "boolean",
		Setting_AutoAim = "boolean",
		IsAFK = "boolean",
		Hardware = "string",
	},
	LocalKeys = {
		ShiftLock = "boolean",
		OpenedEquipment = "boolean",
		ResultShown = "boolean",
		IsSpectating = "boolean",
		Setting_SFXVolume = "number",
		Setting_MusicVolume = "number",
		Setting_PerformanceMode = "boolean",
		Setting_AutoAim = "boolean",
		IsAFK = "boolean",
		Hardware = "string",
	},
}

local function Add(group: string, entries: { { string } })
	table.insert(Groups, group)
	for _, entry in entries do
		Fields[entry[1]] = { Group = group, Kind = entry[2] }
	end
end

Add("Progression", {
	{ "BagScore", "number" },
	{ "Coins", "number" },
	{ "Experience", "number" },
	{ "Level", "number" },
	{ "Playtime", "number" },
})
Add("Statistics", {
	{ "Deaths", "number" },
	{ "GamesPlayed", "number" },
	{ "GlobalRank", "number" },
	{ "GlobalRankOverflow", "boolean" },
	{ "Kills", "number" },
	{ "PeakTrophies", "number" },
	{ "SnapshotRank", "number" },
	{ "Trophies", "number" },
	{ "Wins", "number" },
})
Add("Periods", {
	{ "Coins_Day", "number" },
	{ "Coins_Month", "number" },
	{ "Coins_Week", "number" },
	{ "Kills_Day", "number" },
	{ "Kills_Month", "number" },
	{ "Kills_Week", "number" },
	{ "Wins_Day", "number" },
	{ "Wins_Month", "number" },
	{ "Wins_Week", "number" },
})
Add("Match", {
	{ "ChargeAttack", "boolean" },
	{ "Invisible", "boolean" },
	{ "IsAFK", "boolean" },
	{ "IsFrozen", "boolean" },
	{ "IsInTrainingArea", "boolean" },
	{ "IsInvulnerable", "boolean" },
	{ "IsOnArena", "boolean" },
	{ "Lives", "number" },
	{ "MatchHits", "number" },
	{ "MatchId", "number" },
	{ "MatchKills", "number" },
	{ "MatchStuds", "number" },
	{ "MatchTrophyDelta", "number" },
	{ "TeleportingActive", "boolean" },
	{ "TrophyMatchId", "number" },
})
Add("Settings", {
	{ "Setting_AutoAim", "boolean" },
	{ "Setting_MusicVolume", "number" },
	{ "Setting_PerformanceMode", "boolean" },
	{ "Setting_SFXVolume", "number" },
})
Add("Entitlements", {
	{ "ChestRecoveryRequired", "boolean" },
	{ "DailyRewardDay", "number" },
	{ "DailyRewardLastClaim", "number" },
	{ "DailyWins", "number" },
	{ "DailyWinsClaimed", "boolean" },
	{ "DailyWinsTimestamp", "number" },
	{ "DevAccess", "boolean" },
	{ "EarlyRewardClaimed", "boolean" },
	{ "GamepassesLoaded", "boolean" },
	{ "GroupRewardClaimed", "boolean" },
	{ "Has2xCoins", "boolean" },
	{ "Has2xCoinsBuff", "boolean" },
	{ "TutorialCompleted", "boolean" },
	{ "x2CoinBuffExpiredOn", "number" },
	{ "x2CoinBuffOfflineTimestamp", "number" },
})

Add("Inventory", {
	{ "EquippedWeaponName" },
	{ "EquippedBaseWeapon" },
	{ "EquippedAbility" },
	{ "OwnedWeapons", "string" },
	{ "OwnedAbilities", "string" },
	{ "OwnedChests", "string" },
	{ "CarriedChests" },
})
Add("Session", { { "DataLoaded" } })
table.insert(Groups, "Profile")
table.insert(Groups, "Dynamic")
Fields.Hardware = { Group = "Settings" }
for _, defaults in { Schema.DefaultAttributes, Schema.DefaultSettings, Schema.SessionAttributes } do
	for key, value in defaults do
		local field = Fields[key] or { Group = "Profile" }
		field.Kind = field.Kind or type(value)
		field.Persistence = if defaults == Schema.SessionAttributes then "Session" else "Profile"
		Fields[key] = field
	end
end
for _, field in Fields do
	field.Persistence = field.Persistence or "Session"
	field.Visibility = "Public"
end
Fields.ProcessedGiftReceipts.Visibility = "Server"

return Schema
