--!native
--!optimize 2
-- Combines owned weapons and records the consumed inputs and produced output.
--// Services
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")

--// Modules
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)
local Economy = require(ServerScriptService.Services.AnalyticsService.Economy)
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local WeaponConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("WeaponConfig"))

--// References
local ForgeWeaponFunction = ReplicatedStorage:WaitForChild("Events"):WaitForChild("ForgeWeaponFunction")

local ForgeService = {}

local RARITY_VAL = {Common = 1, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5}
local RARITY_NAME = {"Common", "Rare", "Epic", "Legendary", "Mythic"}

local WeaponDS = DataStoreService:GetDataStore("ExistingWeapons_V1") 

local function getRandomVariant(baseName, rarity)
	local variants = WeaponConfig.RarityVariants[rarity]
	if not variants or #variants == 0 then return baseName end
	return baseName .. variants[math.random(1, #variants)]
end

local function handleForge(player, w1, w2, w3)
	local ownedStr = PlayerData.Get(player, "OwnedWeapons") or ""
	local ownedArr = string.split(ownedStr, ",")
	local toRemove = {w1, w2, w3}
	local baseName = nil

	for _, reqName in ipairs(toRemove) do
		local idx = table.find(ownedArr, reqName)
		if not idx then return false, "Armi mancanti" end

		local info = WeaponConfig.GetWeaponInfo(reqName)
		if not info then return false, "Arma non valida" end
		if info.Variant == "None" then return false, "Impossibile forgiare un'arma Base" end

		if not baseName then baseName = info.BaseName
		elseif baseName ~= info.BaseName then return false, "Tipologie diverse" end

		table.remove(ownedArr, idx)
	end

	-- BRUCIA LE ARMI VECCHIE (Mai sotto lo 0)
	for _, reqName in ipairs(toRemove) do
		local current = ReplicatedValues.GetNumber(ReplicatedStorage, "Existing_" .. reqName) or 1
		ReplicatedValues.Set(ReplicatedStorage, "Existing_" .. reqName, math.max(0, current - 1))

		task.spawn(function()
			pcall(function() 
				-- UpdateAsync assicura che il valore nel database non scenda sotto zero
				WeaponDS:UpdateAsync("Existing_" .. reqName, function(oldValue)
					return math.max(0, (oldValue or 0) - 1)
				end)
			end)
			pcall(function() MessagingService:PublishAsync("WeaponBurned", { wName = reqName, jobId = game.JobId }) end)
		end)
	end

	-- CALCOLA LA NUOVA ARMA
	local sum = RARITY_VAL[WeaponConfig.GetWeaponInfo(w1).Rarity] + RARITY_VAL[WeaponConfig.GetWeaponInfo(w2).Rarity] + RARITY_VAL[WeaponConfig.GetWeaponInfo(w3).Rarity]
	local avg = sum / 3
	local targetIdx = math.min(math.floor(avg) + 1, 5)

	if targetIdx < 5 and math.random() <= (avg % 1) then targetIdx += 1 end

	local newWeapon = getRandomVariant(baseName, RARITY_NAME[targetIdx])
	table.insert(ownedArr, newWeapon)
	PlayerData.Set(player, "OwnedWeapons", table.concat(ownedArr, ","))
	-- Emit gross consumption before output, even if the result matches an input name.
	local balance = Economy.Total(Economy.ListCounts(ownedStr))
	for _, item in toRemove do
		balance -= 1
		AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Sink, Resource = "Weapons",
			Amount = 1, Balance = balance, TransactionType = "Gameplay", ItemSku = item, Activity = "Forge" })
	end
	AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Weapons",
		Amount = 1, Balance = balance + 1, TransactionType = "Gameplay", ItemSku = newWeapon, Activity = "Forge" })

	-- AGGIUNGE LA NUOVA ARMA
	local currentExisting = ReplicatedValues.GetNumber(ReplicatedStorage, "Existing_" .. newWeapon) or 0
	ReplicatedValues.Set(ReplicatedStorage, "Existing_" .. newWeapon, currentExisting + 1)

	task.spawn(function()
		pcall(function() WeaponDS:IncrementAsync("Existing_" .. newWeapon, 1) end)
		pcall(function() MessagingService:PublishAsync("WeaponFound", { wName = newWeapon, jobId = game.JobId }) end)
	end)

	return true, newWeapon
end

function ForgeService.Init()
	ForgeWeaponFunction.OnServerInvoke = handleForge

	pcall(function()
		MessagingService:SubscribeAsync("WeaponBurned", function(msg)
			if msg.Data.jobId ~= game.JobId then
				local current = ReplicatedValues.GetNumber(ReplicatedStorage, "Existing_" .. msg.Data.wName) or 1
				ReplicatedValues.Set(ReplicatedStorage, "Existing_" .. msg.Data.wName, math.max(0, current - 1))
			end
		end)
	end)
end

return ForgeService
