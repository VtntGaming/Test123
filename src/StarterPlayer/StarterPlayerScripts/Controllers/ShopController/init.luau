--!strict

--// Services
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

--// Modules
local ChestItem = require(script.ChestItem)
local ChestConfig = require(ReplicatedStorage.SharedModules.ChestConfig)
local UIInteractionController = require(script.Parent.UIInteractionController)
local NotificationUtil = require(ReplicatedStorage.Utils.NotificationUtil)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local MainGui = LocalPlayer.PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("ShopFrame")
local ScrollHolder = ShopFrame.ScrollHolder
local ShopTemplate = ScrollHolder.ScrollingFrame.ShopTemplate
local RestockText = ShopFrame.RestockText
local RestockButton = ShopFrame.RestockButton
local CloseButton = ShopFrame.ExitButton
local ShopOpenSound = SoundService.SFX.ShopOpen

--// Constants
local RESTOCK_PRODUCT_ID = 3640516882
local TRIGGER_DISTANCE = 6

--// Properties
local IsInShopZone = false
local ShopTrigger: BasePart? = nil

--// Types
export type ShopController = {
	Items: { [string]: ChestItem.ChestItem },
	Init: () -> (),
	Setup: (self: ShopController) -> (),
	Start: (self: ShopController) -> (),
}

local Controller = {} :: ShopController

local function GetSortedChestNames(): { string }
	local chestNames = {}
	for chestName in ChestConfig.Chests do
		table.insert(chestNames, chestName)
	end

	table.sort(chestNames, function(firstName, secondName)
		return ChestConfig.Chests[firstName].Order < ChestConfig.Chests[secondName].Order
	end)
	return chestNames
end

local function PopulateShop()
	if next(Controller.Items) then
		return
	end

	for _, chestName in ipairs(GetSortedChestNames()) do
		Controller.Items[chestName] = ChestItem.new(chestName)
	end
end

local function RevealItems()
	for index, chestName in ipairs(GetSortedChestNames()) do
		local item = Controller.Items[chestName]
		if item then
			item:Reveal(index * 0.08)
		end
	end
end

local function UpdateRestockText()
	local nextRestockTime = tonumber(ReplicatedStorage:GetAttribute("NextRestockTime")) or 0
	if not math.isfinite(nextRestockTime) or nextRestockTime < 0 then
		nextRestockTime = 0
	end

	local secondsRemaining = math.max(0, nextRestockTime - os.time())
	RestockText.Text = string.format(
		"%02d:%02d",
		math.floor(secondsRemaining / 60),
		secondsRemaining % 60
	)
end

local function ToggleEnabled(forceState: boolean?)
	local isOpening = forceState
	if isOpening == nil then
		isOpening = not ShopFrame.Visible
	end
	if ShopFrame.Visible == isOpening then
		return
	end

	UIInteractionController.ToggleFrame(ShopFrame, isOpening)
	if isOpening then
		SoundService:PlayLocalSound(ShopOpenSound)
		PopulateShop()
		RevealItems()
		UpdateRestockText()
	end
end

local function RefreshShopTrigger()
	ShopTrigger = nil
	for _, taggedInstance in ipairs(CollectionService:GetTagged("ShopTrigger")) do
		if taggedInstance:IsA("BasePart") then
			ShopTrigger = taggedInstance
			return
		end
	end
end

local function UpdateShopZone()
	local isInsideShop = false
	local trigger = ShopTrigger
	local character = LocalPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	if trigger and trigger.Parent and rootPart and rootPart:IsA("BasePart") then
		isInsideShop = (rootPart.Position - trigger.Position).Magnitude <= TRIGGER_DISTANCE
	end

	if isInsideShop == IsInShopZone then
		return
	end

	IsInShopZone = isInsideShop
	if isInsideShop then
		if not LocalPlayer:GetAttribute("IsOnArena") then
			ToggleEnabled(true)
		end
	else
		ToggleEnabled(false)
	end
end

function Controller.Init()
	Controller:Setup()
	Controller:Start()
end

function Controller:Setup()
	Controller.Items = {}
	ShopFrame.Visible = false
	ShopTemplate.Visible = false
end

function Controller:Start()
	CloseButton.MouseButton1Click:Connect(function()
		ToggleEnabled(false)
	end)

	RestockButton.MouseButton1Click:Connect(function()
		MarketplaceService:PromptProductPurchase(LocalPlayer, RESTOCK_PRODUCT_ID)
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
		if userId ~= LocalPlayer.UserId or not isPurchased then
			return
		end

		if productId == RESTOCK_PRODUCT_ID then
			NotificationUtil.Show("Success", "Shop successfully restocked!")
			return
		end

		for chestName, chestData in pairs(ChestConfig.Chests) do
			if chestData.ProductId == productId then
				NotificationUtil.Show("Success", "Purchased " .. chestName .. " Chest!")
				return
			end
		end
	end)

	ReplicatedStorage:GetAttributeChangedSignal("NextRestockTime"):Connect(UpdateRestockText)
	task.spawn(function()
		while task.wait(1) do
			if ShopFrame.Visible then
				UpdateRestockText()
			end
		end
	end)

	RefreshShopTrigger()
	CollectionService:GetInstanceAddedSignal("ShopTrigger"):Connect(function(instance)
		if not ShopTrigger and instance:IsA("BasePart") then
			ShopTrigger = instance
		end
	end)
	CollectionService:GetInstanceRemovedSignal("ShopTrigger"):Connect(function(instance)
		if ShopTrigger == instance then
			RefreshShopTrigger()
		end
	end)

	LocalPlayer:GetAttributeChangedSignal("IsOnArena"):Connect(function()
		if IsInShopZone then
			ToggleEnabled(not LocalPlayer:GetAttribute("IsOnArena"))
		end
	end)

	RunService.Heartbeat:Connect(UpdateShopZone)
end

return Controller
