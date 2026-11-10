--!strict
-- Combines Roblox pass ownership with saved gifted entitlements and registers pass gift eligibility.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local AnalyticsService = require(Services.AnalyticsService)
local Monetization = require(Services.AnalyticsService.Monetization)
local PurchaseTypes = require(Services.PurchaseService.Types)
local Runtime = require(Services.Helper.ShopRuntime)
local Registry = require(Services.PurchaseService.ProductRegistry)
local Receipts = require(Services.PurchaseService.Receipts)
local ShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)

--// Properties
local Initialized = false
local ById: { [number]: string } = {}
local Revisions: { [Player]: { [string]: number } } = {}
local Checked: { [Player]: { [string]: boolean } } = {}
local DirectPending: { [Player]: { [string]: boolean } } = {}
local DirectReported: { [Player]: { [string]: boolean } } = {}
local NextRequest: { [Player]: number } = {}
local Prompting: { [Player]: { Token: { Deadline: number, AllowDeparted: boolean? }, ProductId: number } } = {}
local Connections: { [Player]: { PlayerData.Connection } } = {}
local PurchaseRemote: RemoteEvent? = nil
local FeedbackRemote: RemoteEvent? = nil

--// Types
export type Passes = {
	Refresh: (player: Player, passName: string?) -> (),
	RequestPurchase: (player: Player, passName: string) -> (boolean, string?),
	Setup: (self: Passes) -> (),
	Start: (self: Passes) -> (),
	Init: () -> (),
}

--// Service
local Service = {} :: Passes

--// APIs
local function Feedback(player: Player, status: string, passName: string, requestId: string?)
	if player.Parent == Players then
		PlayerData.Set(player, "PassPurchaseStatus", status)
		if FeedbackRemote then
			FeedbackRemote:FireClient(player, status, passName, requestId)
		end
	end
end

local function Attribute(passName: string): string
	return ShopConfig.Passes[passName].Attribute or "Has" .. passName
end

local function GiftAttribute(passName: string): string
	return "Owned_Pass_" .. passName
end

local function GrantPass(player: Player, reward: PurchaseTypes.Reward)
	assert(ShopConfig.Passes[reward.PassName], "Unknown saved pass")
	local newlyGranted = PlayerData.Get(player, GiftAttribute(reward.PassName)) ~= true
		and PlayerData.Get(player, Attribute(reward.PassName)) ~= true
	PlayerData.Set(player, GiftAttribute(reward.PassName), true)
	PlayerData.Set(player, Attribute(reward.PassName), true)
	if newlyGranted then
		AnalyticsService.RecordCustom(player, Monetization.PassAcquired(reward.PassName, "Gift"))
	end
end

-- Sets GamepassesLoaded only after every configured pass has a known ownership result.
-- A false Has* attribute while GamepassesLoaded is false may still mean lookup pending.
local function UpdateLoaded(player: Player)
	for passName in pairs(ShopConfig.Passes) do
		if not Checked[player] or not Checked[player][passName] then
			PlayerData.Set(player, "GamepassesLoaded", false)
			return
		end
	end
	PlayerData.Set(player, "GamepassesLoaded", true)
end

-- Inputs: player, configured pass key, internal retry attempt (omit at call sites).
-- Returns Roblox ownership boolean, or nil + reason on failure/unknown/leaving/stale query.
-- API errors preserve an existing attribute and retry through the shared worker.
local function Refresh(player: Player, passName: string, attempt: number): (boolean?, string?)
	local info = ShopConfig.Passes[passName]
	if not info or player.Parent ~= Players or not Revisions[player] then
		return nil, "Unavailable"
	end
	local versions = Revisions[player]
	versions[passName] = (versions[passName] or 0) + 1
	local version = versions[passName]
	local ok, owned = true, false
	if info.ID > 0 and PlayerData.Get(player, GiftAttribute(passName)) ~= true then
		ok, owned = Runtime.Await(30, function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, info.ID)
		end)
	end
	-- A newer lookup (e.g. purchase completion) owns the attribute now.
	if player.Parent ~= Players or Revisions[player] ~= versions or versions[passName] ~= version then
		return nil, "Superseded"
	end
	if not ok and PlayerData.Get(player, GiftAttribute(passName)) == true then
		ok, owned = true, false
	end
	if not ok then
		Checked[player][passName] = nil
		UpdateLoaded(player)
		warn("[Passes] Ownership check failed for " .. player.UserId .. "/" .. passName .. ": " .. tostring(owned))
		Runtime.Schedule(player, "Pass:" .. passName, function()
			local result = Refresh(player, passName, attempt + 1)
			return result ~= nil
		end)
		return nil, "OwnershipUnavailable"
	end
	-- C4: ownership refresh alone is not evidence of a new direct purchase.
	if owned == true and DirectPending[player][passName] and not DirectReported[player][passName] then
		DirectReported[player][passName] = true
		DirectPending[player][passName] = nil
		AnalyticsService.RecordCustom(player, Monetization.PassAcquired(passName, "Direct"))
	end
	owned = owned or PlayerData.Get(player, GiftAttribute(passName)) == true
	PlayerData.Set(player, Attribute(passName), owned)
	Checked[player][passName] = true
	UpdateLoaded(player)
	Feedback(player, if owned then "Owned" else "NotOwned", passName)
	return owned, nil
end

-- Input: player, optional configured pass key. Returns nothing; refreshes one or all passes.
-- Does not use player-data readiness: these attributes are independent of saved progress.
function Service.Refresh(player, passName)
	if passName then
		Refresh(player, passName, 1)
	else
		for name in pairs(ShopConfig.Passes) do
			Refresh(player, name, 1)
		end
	end
end

-- Inputs: buyer Player and configured key (e.g. "VIP"). Yields for Roblox ownership.
-- Returns true when a prompt opens, otherwise false + reason. No benefits are applied here.
function Service.RequestPurchase(player, passName)
	if not Runtime.Ready(player) then
		return false, "DataNotLoaded"
	end
	if PlayerData.Get(player, "ManagedCheckoutPending") == true or PlayerData.Get(player, "SimpleCheckoutPending") == true then
		return false, "PurchasePending"
	end
	local info = ShopConfig.Passes[passName]
	if not info or info.ID <= 0 or player.Parent ~= Players or not Revisions[player] then
		return false, "Unavailable"
	end
	if PlayerData.Get(player, GiftAttribute(passName)) == true then
		return false, "AlreadyOwned"
	end
	local token = Runtime.Begin(player, "PassPrompt", 120)
	if not token then
		return false, "PurchasePending"
	end
	Prompting[player] = { Token = token, ProductId = info.ID }
	local owned, reason = Refresh(player, passName, 1)
	if not Runtime.Valid(player, "PassPrompt", token) then
		return false, "TimedOut"
	end
	if owned == nil or owned then
		Runtime.Finish(player, "PassPrompt", token)
		Prompting[player] = nil
		return false, reason or "AlreadyOwned"
	end
	local ok, err = Runtime.Await(30, function()
		MarketplaceService:PromptGamePassPurchase(player, info.ID)
	end)
	if not Runtime.Valid(player, "PassPrompt", token) then
		return false, "TimedOut"
	end
	if not ok then
		Runtime.Finish(player, "PassPrompt", token)
		Prompting[player] = nil
		warn("[Passes] Prompt failed: " .. tostring(err))
		return false, "PromptFailed"
	end
	return true, nil
end

local function Watch(player: Player)
	if Revisions[player] then
		return
	end
	Revisions[player], Checked[player] = {}, {}
	DirectPending[player], DirectReported[player] = {}, {}
	PlayerData.Set(player, "GamepassesLoaded", false)
	for passName in pairs(ShopConfig.Passes) do
		PlayerData.Set(player, Attribute(passName), PlayerData.Get(player, GiftAttribute(passName)) == true)
	end
	task.spawn(Service.Refresh, player)
	Connections[player] = {
		PlayerData.Observe(player, "DataLoaded", function()
			if Runtime.Ready(player) then
				task.spawn(Service.Refresh, player)
			end
		end),
	}
	for passName in pairs(ShopConfig.Passes) do
		table.insert(
			Connections[player],
			PlayerData.Observe(player, GiftAttribute(passName), function()
			if PlayerData.Get(player, GiftAttribute(passName)) == true then
				PlayerData.Set(player, Attribute(passName), true)
			end
			end)
		)
	end
end

-- Connects pass ownership refresh and registers developer products for persistent gifts.
-- Clients request configured pass keys; only the server opens purchase prompts.
function Service:Setup()
	local events = ReplicatedStorage.Events
	for _, name in ipairs({ "PassPurchaseEvent", "PassPurchaseFeedbackEvent" }) do
		local remote = events:FindFirstChild(name)
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name, remote.Parent = name, events
		end
		assert(remote:IsA("RemoteEvent"), name .. " must be a RemoteEvent")
		if name == "PassPurchaseEvent" then
			PurchaseRemote = remote
		else
			FeedbackRemote = remote
		end
	end
	Registry.RegisterReward("Pass", GrantPass)
	Receipts.Register("Pass", { Apply = GrantPass })
	local giftProducts: { [number]: { PassName: string } } = {}
	for passName, info in pairs(ShopConfig.Passes) do
		local giftId = info.GiftID or 0
		assert(
			type(giftId) == "number" and giftId >= 0 and giftId < math.huge and giftId % 1 == 0,
			"Invalid pass GiftID"
		)
		if giftId > 0 then
			assert(not giftProducts[giftId], "Duplicate pass GiftID")
			giftProducts[giftId] = { PassName = passName }
		end
	end
	-- Use the shared persistent catalog so retired gift IDs remain recognizable for recovery.
	Receipts.Products("Pass", giftProducts, Registry.Register, function(giftId: number, product: { PassName: string })
		local passName = product.PassName
		return {
			Kind = "Pass",
			Identity = passName,
			SelfAllowed = false,
			Grant = GrantPass,
			RecoveryReward = function(player: Player): (PurchaseTypes.Reward?, string?)
				local live = ShopConfig.Passes[passName]
				if not live or live.GiftID ~= giftId then
					return nil, "Unavailable"
				end
				if PlayerData.Get(player, "GamepassesLoaded") ~= true then
					return nil, "OwnershipUnavailable"
				end
				if
					PlayerData.Get(player, GiftAttribute(passName)) == true
					or PlayerData.Get(player, Attribute(passName)) == true
				then
					return nil, "AlreadyOwned"
				end
				return { PassName = passName }, nil
			end,
			Snapshot = function(buyer: Player, recipient: Player): (PurchaseTypes.Reward?, string?)
				local live = ShopConfig.Passes[passName]
				if not live or live.GiftID ~= giftId then
					return nil, "Unavailable"
				end
				if
					PlayerData.Get(recipient, GiftAttribute(passName)) == true
					or PlayerData.Get(recipient, Attribute(passName)) == true
				then
					return nil, "AlreadyOwned"
				end
				if PlayerData.Get(recipient, "GamepassesLoaded") ~= true then
					return nil, "OwnershipUnavailable"
				end
				return { PassName = passName }, nil
			end,
			Reservation = function()
				return { Key = "Pass:" .. passName, Limit = 1, Used = 0 }
			end,
		}
	end)
	ById = {}
	local attributes = {}
	for passName, info in pairs(ShopConfig.Passes) do
		assert(
			type(info.ID) == "number" and info.ID >= 0 and info.ID < math.huge and info.ID % 1 == 0,
			"Invalid gamepass ID"
		)
		local name = Attribute(passName)
		assert(
			type(name) == "string" and string.sub(name, 1, 3) == "Has" and not attributes[name],
			"Pass attributes must be unique Has* names"
		)
		attributes[name] = true
		if info.ID > 0 then
			assert(not ById[info.ID], "Duplicate gamepass ID")
			ById[info.ID] = passName
		end
	end
end

function Service:Start()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		local passName = ById[passId]
		local prompt = Prompting[player]
		if passName and prompt and prompt.ProductId == passId then
			Runtime.Finish(player, "PassPrompt", prompt.Token)
			Prompting[player] = nil
		end
		if passName and purchased and player.Parent == Players then
			-- Only this server-confirmed signal creates pending acquisition evidence.
			local pending = DirectPending[player]
			if pending and not DirectReported[player][passName] then pending[passName] = true end
			-- This is Roblox's server event; re-query ownership instead of trusting client input.
			Service.Refresh(player, passName)
		elseif passName and not purchased then
			Feedback(player, "Cancelled", passName)
		end
	end)
	if PurchaseRemote then
		PurchaseRemote.OnServerEvent:Connect(function(player, action, requestId)
			if
				type(action) ~= "string"
				or not ShopConfig.Passes[action]
				or type(requestId) ~= "string"
				or #requestId > 64
			then
				return
			end
			if os.clock() < (NextRequest[player] or 0) then
				Feedback(player, "RateLimited", action, requestId)
				return
			end
			NextRequest[player] = os.clock() + 2
			local opened, reason = Service.RequestPurchase(player, action)
			Feedback(player, if opened then "PromptOpen" else reason or "Unavailable", action, requestId)
		end)
	end
	Players.PlayerAdded:Connect(Watch)
	Players.PlayerRemoving:Connect(function(player)
		for _, connection in ipairs(Connections[player] or {}) do
			connection:Disconnect()
		end
		Connections[player] = nil
		Revisions[player], Checked[player], NextRequest[player], Prompting[player] = nil, nil, nil, nil
		DirectPending[player], DirectReported[player] = nil, nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		Watch(player)
	end
end

function Service.Init()
	if Initialized then
		return
	end
	Service:Setup()
	Service:Start()
	Initialized = true
end

return Service
