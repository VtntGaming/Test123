-- Saved chest consumption and pending rewards share the player's profile snapshot.
-- Dependencies are injected so persistence failure/recovery can be tested in isolation.
--// Services
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)
local Economy = require(ServerScriptService.Services.AnalyticsService.Economy)
local DailyConfig = require(ReplicatedStorage.SharedModules.DailyChestConfig)

local ChestOpenings = {}

function ChestOpenings.new(Data, Runtime, Http, Inventory)
	local service = {}

	function service.Finish(player, id)
		return Runtime.Run(player, "ChestOpening", function(token)
			local state = Data.GetChestState(player)
			if state.RecoveryRequired then return false, "ChestRecoveryRequired" end
			local pending = state.Pending
			if not pending or pending.Id ~= id then return false, "UnknownOpening" end
			-- Persist consumption before inventory delivery, including after a failed Begin.
			if not Data.SavePlayer(player, true) or not Runtime.Valid(player, "ChestOpening", token) then
				return false, "SavePending"
			end
			if not pending.Granted then
				local weapons = PlayerData.Get(player, "OwnedWeapons")
				assert(type(weapons) == "string", "Missing weapon inventory")
				PlayerData.Set(
					player,
					"OwnedWeapons",
					if weapons == "" then pending.Weapon else weapons .. "," .. pending.Weapon
				)
				pending.Granted = true
				AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Weapons",
					Amount = 1, Balance = Economy.Total(Economy.ListCounts(weapons)) + 1, TransactionType = "Gameplay",
					ItemSku = pending.Weapon, Activity = if pending.ChestId == DailyConfig.ChestType then "DailyWinsChest" else "ChestOpen" })
			end
			if not Data.SavePlayer(player, true) or not Runtime.Valid(player, "ChestOpening", token) then
				return false, "SavePending"
			end
			-- Granted=true and the weapon are durable together before compaction.
			if state.Pending == pending then state.Pending = nil end
			Runtime.Schedule(player, "ChestProfile", function() return Data.SavePlayer(player, true) end)
			return true, nil
		end)
	end

	function service.Wake(player)
		if not Runtime.Ready(player) then return end
		local state = Data.GetChestState(player)
		if state.RecoveryRequired then return end
		local opening = state.Pending
		if not opening then return end
		local id = opening.Id
		Runtime.Schedule(player, "ChestRecovery", function()
			local pending = Data.GetChestState(player).Pending
			if not pending or pending.Id ~= id then return true end
			return service.Finish(player, id)
		end)
	end

	-- An optional server-owned source consumes a reward entitlement instead of inventory.
	-- Check and Consume must not yield; consumption and Pending share one profile snapshot.
	function service.Begin(player, chestId, resolve, delaySeconds, source)
		local created
		local success, reason = Runtime.Run(player, "ChestOpening", function(token)
			local state = Data.GetChestState(player)
			if state.RecoveryRequired then return false, "ChestRecoveryRequired" end
			if state.Pending then return false, "OpeningPending" end
			local owned
			if source then
				local eligible, eligibilityReason = source.Check()
				if not eligible then return false, eligibilityReason end
			else
				owned = Inventory.Decode(PlayerData.Get(player, "OwnedChests"))
				if (owned[chestId] or 0) <= 0 then return false, "NotOwned" end
			end
			local weapon = resolve()
			if not weapon then return false, "RewardUnavailable" end
			assert(type(weapon) == "string" and weapon ~= "", "Invalid chest reward")
			local encoded
			if owned then
				owned[chestId] -= 1
				if owned[chestId] == 0 then owned[chestId] = nil end
				encoded = Inventory.Encode(owned)
			end
			created = { Id = Http:GenerateGUID(false), ChestId = chestId, Weapon = weapon,
				ClaimAt = os.time() + delaySeconds, Granted = false }
			-- No yields between consumption and pending-reward mutation.
			state.Pending = created
			if source then
				source.Consume()
			else
				PlayerData.Set(player, "OwnedChests", encoded)
				AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Sink, Resource = "Chests",
					Amount = 1, Balance = Economy.Total(owned), TransactionType = "Gameplay",
					ItemSku = chestId, Activity = "ChestOpen" })
			end
			if not Data.SavePlayer(player, true) or not Runtime.Valid(player, "ChestOpening", token) then
				return false, "SavePending"
			end
			return true, nil
		end)
		if not success then
			if created then service.Wake(player) end
			return nil, reason
		end
		return created, nil
	end

	return service
end

return ChestOpenings
