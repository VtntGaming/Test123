--!strict
-- ChestService (SERVER ModuleScript) - V2
-- LuckyBlock-style chests:
--   * every chest in the OwnedChests attribute becomes a Tool in the player's Backpack
--   * equip it and click -> a registered handler rolls a weapon; chest consumption and
--     the pending reward are saved before broadcasting the opening with a one-time code
--   * the opening client answers with that code when the reveal happens (ChestRewardEvent),
--     or after REWARD_TIMEOUT the server grants the weapon anyway
--
-- NEW in V2
--   * PITY system: guaranteed Epic+ / Legendary+ after N openings without one (counters are player
--     attributes "PityEpic" / "PityLegendary" -> add them to your data save so they persist)
--   * weapon "Existing_" count is RESERVED at roll time, so two chests opened at the same moment
--     are accounted for by subsequent rolls on this server
--   * cooldown matches the new animation length
-- OwnedChests / OwnedWeapons / CarriedChests / BuyChestFunction keep working like before.
--
-- FIX: the last remaining chest no longer loses its tool after opening another one.
--   * the tool being opened is flagged with the "Opening" attribute
--   * reconcile() removes the flagged tool first, then un-equipped tools, then equipped ones
--   * openChest() schedules one more reconcile after the consumed tool is destroyed

export type RewardSource = {
	Check: () -> (boolean, string?),
	Consume: () -> (),
}

export type ChestService = {
	Init: () -> (),
	CanOpen: (player: Player) -> (boolean, string?),
	CanEquip: (player: Player) -> (boolean, string?),
	OpenChest: (player: Player, chestName: string) -> (boolean, string?),
	OpenRewardChest: (player: Player, chestName: string, source: RewardSource, tool: Tool) -> (boolean, string?),
	CreateRewardTool: (player: Player, chestName: string, activated: (Tool) -> ()) -> Tool?,
}

local ChestService = {} :: ChestService

type ItemCounts = { [string]: number }
type CountLoad = { Ready: boolean, Revision: number }

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")

local SharedModules = ReplicatedStorage.SharedModules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local RobuxShopConfig = require(SharedModules.RobuxShopConfig)
local PassesConfig = RobuxShopConfig.Passes

local Events = ReplicatedStorage:WaitForChild("Events")
local ToggleCarryChestEvent = Events:WaitForChild("ToggleCarryChestEvent")
local OpenChestEvent = Events:WaitForChild("OpenChestEvent")
local BuyChestFunction = Events:WaitForChild("BuyChestFunction")

-- Client -> server "reveal reached" (same idea as LuckyBlockReward). Created here if missing.
local ChestRewardEvent = Events:FindFirstChild("ChestRewardEvent")
if not ChestRewardEvent then
	ChestRewardEvent = Instance.new("RemoteEvent")
	ChestRewardEvent.Name = "ChestRewardEvent"
	ChestRewardEvent.Parent = Events
end

local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))
local ChestConfig = require(SharedModules:WaitForChild("ChestConfig"))
local ChestInventory = require(SharedModules:WaitForChild("ChestInventory"))
local ChestCatalog = require(SharedModules:WaitForChild("ChestCatalog"))
local Services = game:GetService("ServerScriptService").Services

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local AnalyticsService = require(Services.AnalyticsService)
local Economy = require(Services.AnalyticsService.Economy)
local ShopService = require(Services.ShopService)
local PlayerDataService = require(Services.PlayerDataService)
local Runtime = require(Services.Helper.ShopRuntime)
local RewardRegistry = require(Services.Helper.ChestRewardRegistry)
local NormalChestRewards = require(Services.Helper.NormalChestRewards)
local Openings = require(Services.Helper.ChestOpenings).new(PlayerDataService, Runtime, HttpService, ChestInventory)

local Assets = ReplicatedStorage:WaitForChild("Assets")
local WeaponsFolder = Assets:WaitForChild("Weapons")

-- ==========================================
-- CONFIG
-- ==========================================
local CONFIG = {
	-- where the thrown chest starts, relative to HumanoidRootPart (same values as before)
	FORWARD_OFFSET = -2.3,
	BASE_HEIGHT_OFFSET = -0.5,

	REWARD_TIMEOUT = 14,   -- seconds before the weapon is granted even if the client never answers
	OPEN_COOLDOWN = 1,     -- minimum seconds between two openings (the reveal lands ~6s after the click)
	ENFORCE_LIMITS = true, -- skip weapons whose "Existing_<name>" count reached WeaponConfig.RarityLimits
	ALLOW_LEGACY_OPEN = true, -- OpenChestEvent:FireServer(chestName) from old UI still opens a chest

	-- how the chest looks in the hand (tune in Studio)
	HOLD_SCALE = 0.6,
	HOLD_OFFSET = CFrame.new(0, 0.4, -0.9) * CFrame.Angles(0, math.rad(90), 0),
	TOOL_GRIP = CFrame.new(0, 0, 0),
}

-- Chest tools are unequipped / cannot be opened while any of these is true
local BLOCKING_ATTRIBUTES: { string } = { "IsOnArena", "IsInTrainingArea", "IsFrozen", "TeleportingActive" }

-- ==========================================
-- STATE
-- ==========================================
local WeaponDS = DataStoreService:GetDataStore("ExistingWeapons_V1")
local NormalRewards = NormalChestRewards.new(
	WeaponConfig, WeaponsFolder, ReplicatedStorage, CONFIG.ENFORCE_LIMITS
)
local initialized = false
local nextOpenAt: { [Player]: number } = {}
local reconcilePending: { [Player]: boolean } = {}
local playerConnections: { [Player]: { PlayerData.Connection } } = {}
local characterConnections: { [Player]: RBXScriptConnection } = {}
local CountLoads: { [string]: CountLoad } = {}
local PendingCountLoads = 0
local CountsReady = false

-- ==========================================
-- HELPERS
-- ==========================================
local function getOwned(player: Player): ItemCounts
	return ChestInventory.Decode(PlayerData.Get(player, "OwnedChests"))
end

local function getOwnedNames(counts: ItemCounts): { string }
	local names: { string } = {}
	for itemName, count in counts do
		for _ = 1, count do
			table.insert(names, itemName)
		end
	end
	table.sort(names)
	return names
end

local function isBlocked(player: Player): boolean
	for _, attribute in BLOCKING_ATTRIBUTES do
		if PlayerData.Get(player, attribute) then
			return true
		end
	end

	local char = player.Character
	return not char or char:GetAttribute("IsRagdolled") == true
end

local function ValidCount(value: unknown): boolean
	return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

-- These counters only increase. A delayed snapshot/message cannot erase a newer reservation.
local function MergeCount(weaponName: string, count: number)
	local key = "Existing_" .. weaponName
	ReplicatedValues.Set(ReplicatedStorage, key, math.max(ReplicatedValues.GetNumber(ReplicatedStorage, key) or 0, count))
end

local function LoadCount(weaponName: string)
	local state = CountLoads[weaponName]
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = false
	while not state.Ready do
		local revision = state.Revision
		local success, result = pcall(function()
			return WeaponDS:GetAsync("Existing_" .. weaponName, options)
		end)
		if success and (result == nil or ValidCount(result)) and revision == state.Revision then
			-- Only a successful missing-key read means zero. Failures remain unavailable.
			MergeCount(weaponName, if type(result) == "number" then result else 0)
			state.Ready = true
			PendingCountLoads -= 1
			CountsReady = PendingCountLoads == 0
		else
			if not success or (result ~= nil and not ValidCount(result)) then
				warn("[ChestService] Weapon count unavailable; retrying:", weaponName, result)
			end
			task.wait(5)
		end
	end
	options:Destroy()
end

-- Reserve synchronously before another local roll; persistence and global caps are separate concerns.
local function reserveWeapon(weaponName: string): ()
	assert(CountsReady, "Weapon counts are not ready")
	local existing = ReplicatedValues.GetNumber(ReplicatedStorage, "Existing_" .. weaponName)
	assert(existing ~= nil, "Missing weapon count: " .. weaponName)
	ReplicatedValues.Set(
		ReplicatedStorage,
		"Existing_" .. weaponName,
		existing + 1
	)
	task.spawn(function()
		local success, count = pcall(function() return WeaponDS:IncrementAsync("Existing_" .. weaponName, 1) end)
		if success and type(count) == "number" and ValidCount(count) then
			MergeCount(weaponName, count)
		else
			warn("[ChestService] Weapon count increment failed:", weaponName, count)
		end
		pcall(function()
			MessagingService:PublishAsync("WeaponFound", {
				wName = weaponName, jobId = game.JobId,
				count = if success and type(count) == "number" and ValidCount(count) then count else nil,
			})
		end)
	end)
end

-- forward declaration (used by openChest, defined in the CHEST TOOLS section)
local scheduleReconcile: (player: Player) -> ()

-- ==========================================
-- REWARD (after the animation reaches the reveal)
-- ==========================================
local function grantPending(player: Player, code: string): ()
	if not Runtime.Ready(player) then return end
	local pending = PlayerDataService.GetChestState(player).Pending
	if not pending or pending.Id ~= code then return end
	if not Openings.Finish(player, code) then Openings.Wake(player) end
end

-- ==========================================
-- OPEN A CHEST
-- ==========================================
function ChestService.CanEquip(player)
	if not Runtime.Ready(player) then return false, "DataNotLoaded" end
	if isBlocked(player) then return false, "OpeningBlocked" end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return false, "CharacterUnavailable"
	end
	return true, nil
end

function ChestService.CanOpen(player)
	local canEquip, reason = ChestService.CanEquip(player)
	if not canEquip then return false, reason end
	if not CountsReady then return false, "WeaponCountsLoading" end
	local state = PlayerDataService.GetChestState(player)
	if state.RecoveryRequired then return false, "ChestRecoveryRequired" end
	if state.Pending then return false, "OpeningPending" end
	if os.clock() < (nextOpenAt[player] or 0) then return false, "Cooldown" end
	return true, nil
end

-- tool is optional: Tool.Activated passes it, the legacy OpenChestEvent(chestName) path does not.
local function openChest(player: Player, chestName: unknown, tool: Tool?, source: RewardSource?): (boolean, string?)
	if type(chestName) ~= "string" then return false, "InvalidChest" end
	local canOpen, reason = ChestService.CanOpen(player)
	if not canOpen then return false, reason end

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then return false, "CharacterUnavailable" end

	if not source then
		local owned = getOwned(player)
		if not owned[chestName] or owned[chestName] <= 0 then
			if tool then tool:Destroy() end -- stale tool, the player no longer owns it
			return false, "NotOwned"
		end
	end

	local info = ChestCatalog.Get(chestName)
	if not info then return false, "InvalidChest" end
	local hasInstantChest = PlayerData.Get(player, PassesConfig.InstantChest.Attribute)
	local delay = if hasInstantChest then 0.1 else CONFIG.REWARD_TIMEOUT

	-- FIX: mark the tool being consumed so reconcile() destroys THIS one and not another chest's tool
	if tool then tool:SetAttribute("Opening", true) end

	local pending, openingReason = Openings.Begin(player, chestName, function(): string?
		local weapon = RewardRegistry.Roll(player, info)
		if not weapon or not WeaponConfig.GetWeaponInfo(weapon) or not WeaponsFolder:FindFirstChild(weapon) then
			return nil
		end
		reserveWeapon(weapon)
		return weapon
	end, delay, source)

	if not pending then
		if tool then tool:SetAttribute("Opening", nil) end
		return false, openingReason
	end

	if tool then tool:Destroy() end
	-- FIX: safety net, make sure the remaining chests still have their tools
	scheduleReconcile(player)

	nextOpenAt[player] = os.clock() + (if hasInstantChest then 0 else CONFIG.OPEN_COOLDOWN)
	-- Saving may yield; use the current character instead of an obsolete root.
	char = player.Character
	root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or isBlocked(player) then
		grantPending(player, pending.Id)
		return true, nil
	end
	OpenChestEvent:FireAllClients(
		player,
		chestName,
		root.CFrame * CFrame.new(0, CONFIG.BASE_HEIGHT_OFFSET, CONFIG.FORWARD_OFFSET),
		pending.Weapon,
		pending.Id,
		hasInstantChest == true
	)

	task.delay(delay, function()
		grantPending(player, pending.Id)
	end)
	return true, nil
end

function ChestService.OpenChest(player, chestName)
	return openChest(player, chestName, nil)
end

function ChestService.OpenRewardChest(player, chestName, source, tool)
	return openChest(player, chestName, tool, source)
end

-- ==========================================
-- CHEST TOOLS (OwnedChests -> Tools in the Backpack)
-- ==========================================
local function createChestTool(player: Player, chestName: string, activated: ((Tool) -> ())?): Tool?
	local info = ChestCatalog.Get(chestName)
	local template = info and info.ModelPath
	if not info then return nil end

	local tool = Instance.new("Tool")
	tool.Name = info.DisplayName
	tool.ToolTip = info.DisplayName .. " - Click to open"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.Grip = CONFIG.TOOL_GRIP
	tool.TextureId = info.Thumbnail
	tool:SetAttribute("ChestName", chestName)
	if activated then tool:SetAttribute("RewardChest", true) end

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.Transparency = 1
	handle.CanCollide, handle.CanTouch, handle.CanQuery, handle.Massless = false, false, false, true
	handle.CFrame = CFrame.new()
	handle.Parent = tool

	local visual = template and template:Clone()
	local primary = visual and (visual.PrimaryPart or visual:FindFirstChild("Base") or visual:FindFirstChildWhichIsA("BasePart", true))
	if primary then
		visual.PrimaryPart = primary
		visual:ScaleTo(CONFIG.HOLD_SCALE)
		visual:PivotTo(handle.CFrame * CONFIG.HOLD_OFFSET)
		for _, part in visual:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.Massless = false, false, false, false, true
				if part ~= primary then
					local weld = Instance.new("WeldConstraint")
					weld.Part0, weld.Part1, weld.Parent = primary, part, primary
				end
			end
		end
		local hold = Instance.new("WeldConstraint")
		hold.Part0, hold.Part1, hold.Parent = handle, primary, handle
		visual.Name = "ChestVisual"
		visual.Parent = tool
	elseif visual then
		visual:Destroy()
	end

	tool.Activated:Connect(function()
		if activated then activated(tool) else openChest(player, chestName, tool) end
	end)
	return tool
end

function ChestService.CreateRewardTool(player, chestName, activated)
	return createChestTool(player, chestName, activated)
end

local function collectChestTools(player: Player): { [string]: { Tool } }
	local result: { [string]: { Tool } } = {}
	local function scan(container: Instance?): ()
		if not container then return end
		for _, child in container:GetChildren() do
			if child:IsA("Tool") and child:GetAttribute("RewardChest") ~= true then
				local chestName = child:GetAttribute("ChestName")
				if type(chestName) == "string" then
					result[chestName] = result[chestName] or {}
					table.insert(result[chestName], child)
				end
			end
		end
	end
	scan(player:FindFirstChildOfClass("Backpack"))
	scan(player.Character)
	return result
end

-- Keeps the old "CarriedChests" attribute alive for UI scripts: slot index of the held chest, or "".
local function syncCarried(player: Player): ()
	local carried = ""
	local char = player.Character
	if char then
		for _, child in char:GetChildren() do
			if child:IsA("Tool") and child:GetAttribute("ChestName") then
				local slot = child:GetAttribute("Slot")
				if slot then carried = tostring(slot) end
				break
			end
		end
	end
	if PlayerData.Get(player, "CarriedChests") ~= carried then
		PlayerData.Set(player, "CarriedChests", carried)
	end
end

-- Makes the tools match OwnedChests exactly (creates missing ones, removes extras).
local function reconcile(player: Player): ()
	if player.Parent ~= Players then return end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then return end

	local owned = getOwned(player)

	local tools = collectChestTools(player)

	-- remove extras (tool being opened first, then un-equipped, then equipped)
	for name, list in tools do
		local extra = #list - (owned[name] or 0)
		if extra > 0 then
			local function rank(t: Tool): number
				if t:GetAttribute("Opening") then return 0 end
				return if t.Parent == player.Character then 2 else 1
			end
			table.sort(list, function(a, b) return rank(a) < rank(b) end)
			for _ = 1, extra do
				local t = table.remove(list, 1)
				if t then t:Destroy() end
			end
		end
	end

	-- create missing
	for name, count in owned do
		tools[name] = tools[name] or {}
		for _ = #tools[name] + 1, count do
			local tool = createChestTool(player, name)
			if tool then
				tool.Parent = backpack
				table.insert(tools[name], tool)
			end
		end
	end

	-- Assign slot numbers from the expanded, sorted chest counts.
	local used: ItemCounts = {}
	for slot, name in ipairs(getOwnedNames(owned)) do
		used[name] = (used[name] or 0) + 1
		local list = tools[name]
		local tool = list and list[used[name]]
		if tool then tool:SetAttribute("Slot", slot) end
	end

	syncCarried(player)
end

scheduleReconcile = function(player: Player): ()
	if reconcilePending[player] then return end
	reconcilePending[player] = true
	task.defer(function()
		reconcilePending[player] = nil
		reconcile(player)
	end)
end

local function unequipChestTools(player: Player): ()
	local char = player.Character
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not char or not backpack then return end
	for _, child in char:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("ChestName") then
			child.Parent = backpack
		end
	end
end

-- Old UI event: clicking a chest in the inventory equips / unequips its tool.
local function toggleCarry(player: Player, chestName: unknown): ()
	if type(chestName) ~= "string" or isBlocked(player) then return end
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not humanoid or humanoid.Health <= 0 then return end

	for _, child in char:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("ChestName") == chestName then
			humanoid:UnequipTools()
			return
		end
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then return end
	for _, child in backpack:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("ChestName") == chestName then
			humanoid:EquipTool(child)
			return
		end
	end
end

-- ==========================================
-- SHOP (unchanged)
-- ==========================================
local function buyChest(player: Player, chestName: string, currencyType: string): (boolean, string)
	if currencyType == "Coins" then
		local currentStock = ReplicatedValues.GetNumber(ReplicatedStorage, "Stock_" .. chestName) or 0
		if currentStock <= 0 then return false, "Chest is Out of Stock!" end
	end

	local chestInfo = ChestConfig.GetChestInfo(chestName)
	if not chestInfo then return false, "Chest non trovata!" end
	if currencyType ~= "Coins" then return false, "Use the product purchase prompt" end

	local currentCoins = (PlayerData.Get(player, "Coins") or 0) :: number
	local stockOrigin = ShopService.GetStockOrigin()
	if currencyType == "Coins" and currentCoins < chestInfo.Cost then return false, "Not enough Coins!" end

	if currencyType == "Coins" then
		PlayerData.Set(player, "Coins", math.round(currentCoins - chestInfo.Cost))
		ReplicatedValues.Set(
			ReplicatedStorage,
			"Stock_" .. chestName,
			(ReplicatedValues.GetNumber(ReplicatedStorage, "Stock_" .. chestName) or 0) - 1
		)
	end

	local ownedChests = getOwned(player)
	ownedChests[chestName] = (ownedChests[chestName] or 0) + 1
	PlayerData.Set(player, "OwnedChests", ChestInventory.Encode(ownedChests))
	AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Sink, Resource = "Coins",
		Amount = currentCoins - math.round(currentCoins - chestInfo.Cost), Balance = math.round(currentCoins - chestInfo.Cost),
		TransactionType = "Shop", ItemSku = chestName, Activity = "ChestPurchase", Context = stockOrigin })
	AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Chests",
		Amount = 1, Balance = Economy.Total(ownedChests), TransactionType = "Shop",
		ItemSku = chestName, Activity = "ChestPurchase", Context = stockOrigin })

	return true, "Purchased " .. chestName .. " Chest!"
end

-- ==========================================
-- PLAYERS
-- ==========================================
local function setupPlayer(player: Player): ()
	if playerConnections[player] then return end
	local connections: { PlayerData.Connection } = {}
	playerConnections[player] = connections
	table.insert(connections, PlayerData.Observe(player, "DataLoaded", function()
		if Runtime.Ready(player) then
			Openings.Wake(player)
			scheduleReconcile(player)
		end
	end))
	if Runtime.Ready(player) then Openings.Wake(player) end

	table.insert(connections, PlayerData.Observe(player, "OwnedChests", function()
		scheduleReconcile(player)
	end))

	for _, attribute in BLOCKING_ATTRIBUTES do
		table.insert(connections, PlayerData.Observe(player, attribute, function()
			if PlayerData.Get(player, attribute) then
				unequipChestTools(player)
			end
		end))
	end

	local function onCharacter(char: Model): ()
		char.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then task.defer(syncCarried, player) end
		end)
		char.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then task.defer(syncCarried, player) end
		end)
		syncCarried(player)
		task.delay(0.25, scheduleReconcile, player) -- the new Backpack needs a moment after a respawn
	end
	characterConnections[player] = player.CharacterAdded:Connect(onCharacter)
	if player.Character then onCharacter(player.Character) end

	scheduleReconcile(player)
end

-- ==========================================
-- INIT
-- ==========================================
function ChestService.Init(): ()
	if initialized then return end
	initialized = true
	RewardRegistry.Register("Normal", NormalRewards.Roll)
	local pools = NormalRewards.BuildPools()

	for _, list in pools do
		for _, wName in list do
			if not CountLoads[wName] then
				CountLoads[wName] = { Ready = false, Revision = 0 }
				PendingCountLoads += 1
			end
		end
	end

	pcall(function()
		MessagingService:SubscribeAsync("WeaponFound", function(msg)
			local data = msg.Data
			if type(data) ~= "table" or data.jobId == game.JobId or type(data.wName) ~= "string" then return end
			local state = CountLoads[data.wName]
			if not state then return end
			if type(data.count) == "number" and ValidCount(data.count) then
				-- Absolute totals are idempotent and can safely overlap an in-flight read.
				MergeCount(data.wName, data.count)
			elseif data.count == nil then
				-- Older servers send only +1. Re-read after an overlapping message rather
				-- than guessing whether that increment was included in the snapshot.
				state.Revision += 1
				if state.Ready then
					local key = "Existing_" .. data.wName
					ReplicatedValues.Set(ReplicatedStorage, key, (ReplicatedValues.GetNumber(ReplicatedStorage, key) or 0) + 1)
				end
			end
		end)
	end)
	CountsReady = PendingCountLoads == 0
	for weaponName in CountLoads do
		task.spawn(LoadCount, weaponName)
	end

	Players.PlayerAdded:Connect(setupPlayer)
	for _, player in Players:GetPlayers() do setupPlayer(player) end

	Players.PlayerRemoving:Connect(function(player)
		for _, connection in ipairs(playerConnections[player] or {}) do connection:Disconnect() end
		playerConnections[player] = nil
		if characterConnections[player] then
			characterConnections[player]:Disconnect()
		end
		characterConnections[player] = nil
		nextOpenAt[player], reconcilePending[player] = nil, nil
	end)

	ToggleCarryChestEvent.OnServerEvent:Connect(toggleCarry)

	-- legacy: some UI may still fire OpenChestEvent:FireServer(chestName) to open a chest directly
	if CONFIG.ALLOW_LEGACY_OPEN then
		OpenChestEvent.OnServerEvent:Connect(function(player, chestName)
			openChest(player, chestName, nil)
		end)
	end

	ChestRewardEvent.OnServerEvent:Connect(function(player, code)
		if type(code) == "string" then grantPending(player, code) end
	end)

	BuyChestFunction.OnServerInvoke = buyChest
end

return ChestService
