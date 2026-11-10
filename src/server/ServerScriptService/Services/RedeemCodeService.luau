-- Redeems configured promo codes and grants their coin, item or ability rewards.
--// Services
local ServerScriptService = game:GetService("ServerScriptService")

--// Modules
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)
local Economy = require(ServerScriptService.Services.AnalyticsService.Economy)
local Monetization = require(ServerScriptService.Services.AnalyticsService.Monetization)

local CodeService = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local ConfigService = game:GetService("ConfigService")

local RedeemFunction = ReplicatedStorage:WaitForChild("Events"):WaitForChild("RedeemCodeFunction")
local PlayerData = require(ReplicatedStorage.PlayerData)
local CoinsUtils = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("CoinsUtil"))
local ChestInventory = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("ChestInventory")) 
--local RawCodes = require(ReplicatedStorage.SharedModules:WaitForChild("RedeemCodeConfig"))

local CODE_CONFIG = "RedeemCode"


local configSnapshot: ConfigSnapshot? = nil 
-- normalise keys to uppercase so matching is case-insensitive
type CodeData = {
	Type: string,
	Item: string?,
	Quantity: number?
}
local Codes = {} :: {
	[string]: CodeData
}

-- for name, data in pairs(RawCodes) do
-- 	Codes[string.upper(name)] = data
-- end

local lastTry = {}

local function reward(player: Player, code: string, codeData: CodeData): string
	if codeData.Type == "Coin" then
		if not codeData.Quantity then
			error(`{code}: Quantity not found`)
		end
		local amount, balance, vipBonus = CoinsUtils:GiveCoins(player, codeData.Quantity)
		AnalyticsService.RecordEconomy(player, {
			Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins", Amount = amount, Balance = balance,
			TransactionType = "Gameplay", ItemSku = "RedeemCode", Activity = "RedeemCode", Context = "2xNotApplied",
		})
		AnalyticsService.RecordCustom(player, Monetization.VipBonus(player, vipBonus, "RedeemCode", "2xNotApplied"))
		return `Received {amount} Coins!`
	elseif codeData.Type == "Weapon" then
		if not codeData.Quantity or not codeData.Item then
			error(`{code}: Quantity or Item not found`)
		end
		local quantity = codeData.Quantity
		assert(type(quantity) == "number" and quantity > 0 and quantity < math.huge and quantity % 1 == 0,
			`{code}: Quantity must be a positive integer`)
		local weapons = PlayerData.Get(player, "OwnedWeapons")
		assert(type(weapons) == "string", "Missing weapon inventory")
		local bundle = table.concat(table.create(quantity, codeData.Item), ",")
		PlayerData.Set(player, "OwnedWeapons", if weapons == "" then bundle else weapons .. "," .. bundle)
		AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Weapons",
			Amount = quantity, Balance = Economy.Total(Economy.ListCounts(weapons)) + quantity,
			TransactionType = "Gameplay", ItemSku = codeData.Item, Activity = "RedeemCode" })
		return `Received {quantity}x {codeData.Item} weapon!`
	elseif codeData.Type == "Ability" then
		if not codeData.Item then
			error(`{code}: Item not found`)
		end
		local owned = PlayerData.Get(player, "OwnedAbilities")
		assert(type(owned) == "string", "Missing weapon inventory")
		PlayerData.Set(player, "OwnedAbilities", if owned == "" then codeData.Item else owned .. "," .. codeData.Item)
		AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Abilities",
			Amount = 1, Balance = Economy.Total(Economy.ListCounts(owned)) + 1,
			TransactionType = "Gameplay", ItemSku = codeData.Item, Activity = "RedeemCode" })
		return `Received {codeData.Item} ability!`
	elseif codeData.Type == "Chest" then
		if not codeData.Quantity or not codeData.Item then
			error(`{code}: Quantity or Item not found`)
		end
		local quantity = codeData.Quantity
		assert(type(quantity) == "number" and quantity > 0 and quantity < math.huge and quantity % 1 == 0,
			`{code}: Quantity must be a positive integer`)
		local ownedChests = ChestInventory.Decode(PlayerData.Get(player, "OwnedChests"))
		ownedChests[codeData.Item] = (ownedChests[codeData.Item] or 0) + quantity
		PlayerData.Set(player, "OwnedChests", ChestInventory.Encode(ownedChests))
		AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Chests",
			Amount = quantity, Balance = Economy.Total(ownedChests),
			TransactionType = "Gameplay", ItemSku = codeData.Item, Activity = "RedeemCode" })
		return `Received {quantity}x {codeData.Item} chest!`
	else
		error(`{code}: Invalid code type`)
	end
end
local function getRedeemed(player)
	local set = {}
	for _, c in ipairs(string.split((PlayerData.Get(player, "RedeemedCodes") :: string?) or "", ",")) do
		if c ~= "" then set[c] = true end
	end
	return set
end

local function setRedeemed(player, set)
	local list = {}
	for c in pairs(set) do table.insert(list, c) end
	PlayerData.Set(player, "RedeemedCodes", table.concat(list, ","))
end

local function redeem(player, input)
	if type(input) ~= "string" or #input > 50 then return false, "Invalid code" end
	if not PlayerData.Get(player, "DataLoaded") then
		return false, "Data is still loading, try again"
	end

	-- simple rate limit
	local now = os.clock()
	if lastTry[player] and now - lastTry[player] < 1 then return false, "Slow down!" end
	lastTry[player] = now

	local cleaned = input:gsub("%s", "")
	local code = string.upper(cleaned)

	local data = Codes[code]
	if not data or data.Enabled == false then return false, "Invalid code" end
	if data.Expires and os.time() > data.Expires then return false, "This code has expired" end

	local redeemed = getRedeemed(player)
	if redeemed[code] then return false, "You already used this code" end

	-- mark as used BEFORE giving the reward, so spamming can't double redeem
	redeemed[code] = true
	setRedeemed(player, redeemed)

	local ok, result = pcall(reward, player, code, data)
	if not ok then
		warn("Code reward failed for " .. code .. ": " .. tostring(result))
		redeemed[code] = nil
		setRedeemed(player, redeemed)
		return false, "Something went wrong, try again"
	end

	-- optional: save right away so the code can't be reused after a crash
	-- task.spawn(PlayerDataService.SavePlayer, player, true)

	return true, data.Message or "Code redeemed!", result
end

function CodeService.Init()
	RedeemFunction.OnServerInvoke = redeem
	Players.PlayerRemoving:Connect(function(p) lastTry[p] = nil end)
	
    task.spawn(function()
		while not configSnapshot do
			local success,result = pcall(function(...) 
				configSnapshot = ConfigService:GetConfigAsync()
			end)
			if not success then
				task.spawn(function()
					error(result)
				end)
				configSnapshot = nil
			end
			task.wait(2.5)
		end
		
		if configSnapshot then
			configSnapshot.UpdateAvailable:Connect(function() 
				configSnapshot:Refresh()
			end)
		end
		
		local getCode = function()
			if not configSnapshot then
				return {}
			end
			local codeTable = configSnapshot:GetValue(CODE_CONFIG)
			if codeTable and typeof(codeTable) == "table" then
				for name, data in pairs(codeTable) do
					codeTable[string.upper(name)] = data
				end
				return codeTable
			end
			return {}
		end
		Codes = getCode()
		while true do
			task.wait(10)
			Codes = getCode()
		end
    end)
end

return CodeService
