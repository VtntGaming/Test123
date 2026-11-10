--!strict

--// Services
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local ChestConfig = require(ReplicatedStorage.SharedModules.ChestConfig)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local NotificationUtil = require(ReplicatedStorage.Utils.NotificationUtil)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local MainGui = LocalPlayer.PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("ShopFrame")
local ScrollHolder = ShopFrame:WaitForChild("ScrollHolder")
local ScrollingFrame = ScrollHolder:WaitForChild("ScrollingFrame")
local ShopTemplate = ScrollingFrame:WaitForChild("ShopTemplate")
local BuyChestFunction = ReplicatedStorage.Events.BuyChestFunction

--// Constants
local RARITY_ORDER: { string } =
	{ "Common", "Rare", "Epic", "Legendary", "Mythic" }
local REVEAL_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local ROBUX_SYMBOL = "\u{e002}"

--// Properties
local IsPurchasePending = false

--// Types
export type FrameType = typeof(ShopTemplate)

export type ChestItem = {
	__index: ChestItem,
	Frame: FrameType,
	Name: string,
	Data: ChestConfig.ChestData,
	Connections: { RBXScriptConnection },
	Destroyed: boolean,
	new: (chestName: string) -> ChestItem,
	SetupRates: (self: ChestItem) -> (),
	Start: (self: ChestItem) -> (),
	UpdateStock: (self: ChestItem) -> (),
	Reveal: (self: ChestItem, delaySeconds: number) -> (),
	Destroy: (self: ChestItem) -> (),
}

local function FormatNumber(n: number) -- 38699 → "38,699"
	local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

local ChestItem = {} :: ChestItem
ChestItem.__index = ChestItem

function ChestItem.new(chestName: string): ChestItem
	local data = ChestConfig.Chests[chestName]

	local frame = ShopTemplate:Clone()

	local self = setmetatable({}, ChestItem) :: ChestItem
	self.Frame = frame
	self.Name = chestName
	self.Data = data
	self.Connections = {}
	self.Destroyed = false

	frame.Name = self.Name
	frame.Visible = true
	frame.Parent = ScrollingFrame

	local uiScale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	uiScale.Scale = 0
	uiScale.Parent = frame

	local container = frame.ChestContainer

	local title = frame.Title
	title.Text = self.Name

	local icon = container.Icon
	icon.Image = data.Thumbnail

	local sunburst = container.Sunburst
	sunburst.ImageColor3 = data.Color

	local robuxButton = frame.ButtonList.BuyWRobuxButton
	local robuxLabel = robuxButton.Value
	robuxLabel.Text = `{ROBUX_SYMBOL} {FormatNumber(data.CostInRobux)}`	
	
	local background = container.Background
	background.ImageColor3 = data.Color
	
	self:Start()
	return self
end

function ChestItem:SetupRates()
	local frame = self.Frame
	local rateList = frame.WeaponsRates.ScrollingFrame
	local rateTemplate = rateList.WeaponContainer

	rateTemplate.Visible = false

	local updateCallbacks = {}
	local callbackLater = {}
	local minOrder = #RARITY_ORDER

	for rarityOrder, rarityName in ipairs(RARITY_ORDER) do
		minOrder = math.min(minOrder, rarityOrder)
		local rateValue = tonumber(self.Data.Rates[rarityName])
		if rateValue and math.isfinite(rateValue) and rateValue > 0 then
			local rateClone = rateTemplate:Clone()
			rateClone.Name = rarityName
			rateClone.Visible = true
			rateClone.Parent = rateList

			local rarityColor = WeaponConfig.Rarities[rarityName] or Color3.new(1, 1, 1)
			local rarityLabel = rateClone.Rarity
			local rateLabel = rateClone.Rate

			rarityLabel.Text = rarityName
			rarityLabel.TextColor3 = rarityColor

			rateLabel.Text = `{rateValue}%`
			rateLabel.TextColor3 = rarityColor

			local sunburst = rateClone.Sunburst
			sunburst.ImageColor3 = rarityColor

			local background = rateClone.Background
			background.ImageColor3 = rarityColor
			
			local listing = WeaponConfig.RarityWeaponIcons[rarityName]			

			if listing then
				local icon = rateClone.Icon
				local preview = rateClone.Preview
				local order = 0

				local currentData = listing[1]

				table.insert(updateCallbacks, function()
					order += 1
					if order > #listing then
						order = 1
					end

					currentData = listing[order]
					local image = currentData.Icon
					preview.Image = image
				end)

				table.insert(callbackLater, function()
					local image = currentData.Icon

					TweenUtils.PlayTweenSequence({
						(rarityOrder - minOrder) * 0.1,
						TweenService:Create(icon.UIScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {Scale = 0}),
						function()							
							icon.Image = image
						end,
						TweenService:Create(icon.UIScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),						
					})
				end)
			end
		end
	end

	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, cb in updateCallbacks do
				pcall(cb)
			end
			task.wait(2.5)
			for _, cb in callbackLater do
				pcall(cb)
			end
		end
	end)
end

function ChestItem:Start()
	local buttonList = self.Frame.ButtonList
	local robuxButton = buttonList.BuyWRobuxButton
	table.insert(self.Connections, robuxButton.Activated:Connect(function()
		MarketplaceService:PromptProductPurchase(LocalPlayer, self.Data.ProductId)
	end))

	local coinsButton = buttonList.BuyWCoinsButton
	table.insert(self.Connections, coinsButton.Activated:Connect(function()
		if IsPurchasePending then
			return
		end

		IsPurchasePending = true
		task.spawn(function()
			local result = table.pack(pcall(function()
				return BuyChestFunction:InvokeServer(self.Name, "Coins")
			end))
			local callSucceeded = result[1]
			local purchaseSucceeded = result[2]
			local message = result[3]

			if not callSucceeded then
				warn("[ChestItem] Chest purchase request failed:", purchaseSucceeded)
				NotificationUtil.Show("Error", "Unable to complete the chest purchase.")
			elseif typeof(purchaseSucceeded) ~= "boolean" then
				warn("[ChestItem] BuyChestFunction returned an invalid purchase result")
				NotificationUtil.Show("Error", "The purchase response was invalid.")
			else
				NotificationUtil.Show(
					if purchaseSucceeded then "Success" else "Error",
					tostring(message)
				)
			end

			task.delay(0.3, function()
				IsPurchasePending = false
			end)
		end)
	end))

	table.insert(
		self.Connections,
		ReplicatedStorage:GetAttributeChangedSignal("Stock_" .. self.Name):Connect(function()
			self:UpdateStock()
		end)
	)

	task.delay(math.random(), function()
		local chestIcon = self.Frame.ChestContainer.Icon

		TweenService:Create(chestIcon, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			Position = UDim2.fromScale(0.5, 0.4)
		}):Play()
		while true do
			TweenUtils.PlayTweenSequence({
				TweenService:Create(chestIcon, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Rotation = 5
				}),
				TweenService:Create(chestIcon, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Rotation = -5
				})
			}, true)
		end		
	end)
	
	self:UpdateStock()
	self:SetupRates()
end

function ChestItem:UpdateStock()
	local currentStock = ReplicatedStorage:GetAttribute("Stock_" .. self.Name)
	if typeof(currentStock) ~= "number" then
		currentStock = 0
	end

	local stockLabel = self.Frame.ChestContainer.StockContainer.Stock
	if currentStock > 0 then
		stockLabel.Text = tostring(currentStock) .. " IN STOCK"
	else
		stockLabel.Text = "NO STOCK"		
	end

	local buyButton = self.Frame.ButtonList.BuyWCoinsButton

	local hasStock = currentStock > 0
	buyButton.Interactable = hasStock
	buyButton.ImageTransparency = if hasStock then 0 else 0.5

	local priceLabel = buyButton.Display.Value
	local icon = buyButton.Display.Icon
	icon.Visible = hasStock
	if hasStock then
		priceLabel.Text = FormatNumber(self.Data.Cost)
	else
		priceLabel.Text = "NO STOCK"
	end
end

function ChestItem:Reveal(delaySeconds: number)
	local uiScale = self.Frame:FindFirstChildOfClass("UIScale")
	if not uiScale then
		return
	end

	uiScale.Scale = 0
	task.delay(delaySeconds, function()
		if not self.Destroyed and self.Frame.Parent then
			TweenService:Create(uiScale, REVEAL_TWEEN_INFO, { Scale = 1 }):Play()
		end
	end)
end

function ChestItem:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true

	for _, connection in ipairs(self.Connections) do
		connection:Disconnect()
	end
	table.clear(self.Connections)
	self.Frame:Destroy()
end

return ChestItem
