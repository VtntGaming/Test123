-- Presents inventory controller behavior using logical Player data access.
local InventoryController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local SoundService = game:GetService("SoundService")
local PlayerData = require(ReplicatedStorage.PlayerData)
local UIInteractionController = require(script.Parent:WaitForChild("UIInteractionController"))
local ChestInventory = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("ChestInventory"))
local ChestCatalog = require(ReplicatedStorage.SharedModules.ChestCatalog)

-- ==========================================
-- CONSTANTS & VARIABLES
-- ==========================================
local RARITY_COLORS = { Common = "#C8C8C8", Rare = "#4DA6FF", Epic = "#A855F7", Legendary = "#FFD700", Mythic = "#FF4444" }
local RARITY_ORDER = { "Common", "Rare", "Epic", "Legendary", "Mythic" }

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local OpenChestEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("OpenChestEvent")
local InventoryOpenSound = SoundService.SFX.InventoryUIOpen

local ui = {}
local state = { selectedChest = nil }

-- ==========================================
-- UTILS
-- ==========================================
local function formatRates(rates)
	local lines = {}
	for _, rarity in ipairs(RARITY_ORDER) do
		table.insert(lines, string.format('<font color="%s">%s:</font> <font color="#FFFFFF">%d%%</font>', RARITY_COLORS[rarity], string.upper(rarity), rates[rarity]))
	end
	return table.concat(lines, "\n")
end

local function getChestCounts()
	return ChestInventory.Decode(PlayerData.Get(LocalPlayer, "OwnedChests"))
end

-- ==========================================
-- CORE LOGIC
-- ==========================================
function InventoryController.Refresh()
	for _, child in ipairs(ui.ScrollingFrame:GetChildren()) do
		if child:IsA("GuiObject") and child ~= ui.Template then child:Destroy() end
	end

	local chestCounts = getChestCounts()

	for chestName, count in pairs(chestCounts) do
		local info = ChestCatalog.Get(chestName)
		if not info then continue end

		local clone = ui.Template:Clone()
		clone.Name = chestName
		clone.Icon.Image = info.Thumbnail
		clone.Title.Text = info.DisplayName
		clone.QuantityLabel.Text = "X" .. count
		clone.Visible = true
		clone.Parent = ui.ScrollingFrame

		clone.MouseButton1Click:Connect(function()
			if state.selectedChest == chestName then
				UIInteractionController.ToggleFrame(ui.SidePopUp, false, false)
				state.selectedChest = nil
			else
				state.selectedChest = chestName
				ui.SidePopUp.Icon.Image = info.Thumbnail
				ui.SidePopUp.Title.Text = info.DisplayName
				ui.SidePopUp.QuantityLabel.Text = "X" .. count
				ui.SidePopUp.ChanceLabel.Text = info.Description or formatRates(info.Rates)
				UIInteractionController.ToggleFrame(ui.SidePopUp, true, false)
			end
		end)
	end

	if state.selectedChest and chestCounts[state.selectedChest] then
		ui.SidePopUp.QuantityLabel.Text = "X" .. chestCounts[state.selectedChest]
	elseif state.selectedChest and not chestCounts[state.selectedChest] then
		UIInteractionController.ToggleFrame(ui.SidePopUp, false, false)
		state.selectedChest = nil
	end
end

function InventoryController.Toggle(forceState)
	local isOpening = forceState ~= nil and forceState or not ui.InventoryFrame.Visible
	if isOpening then InventoryController.Refresh() else UIInteractionController.ToggleFrame(ui.SidePopUp, false, false) state.selectedChest = nil end
	UIInteractionController.ToggleFrame(ui.InventoryFrame, isOpening)

	if isOpening then
		SoundService:PlayLocalSound(InventoryOpenSound)
	end
end

function InventoryController.Init()
	ui.MainGui = PlayerGui:WaitForChild("MainGui")
	ui.InventoryFrame = ui.MainGui:WaitForChild("InventoryFrame")
	ui.ScrollingFrame = ui.InventoryFrame:WaitForChild("ScrollHolder"):WaitForChild("ScrollingFrame")
	ui.Template = ui.ScrollingFrame:WaitForChild("Template")
	ui.SidePopUp = ui.InventoryFrame:WaitForChild("SidePopUp")

	CollectionService:AddTag(ui.SidePopUp, "PopUpFrame")

	ui.Template.Visible = false
	ui.SidePopUp.Visible = false
	ui.SidePopUp.ChanceLabel.RichText = true

	-- local inventoryButton = ui.MainGui:WaitForChild("HUD"):WaitForChild("LeftButtons"):WaitForChild("ButtonList"):WaitForChild("InventoryButton")
	-- local invClickTarget = inventoryButton:FindFirstChildOfClass("ImageButton", true) or inventoryButton

	-- invClickTarget.MouseButton1Click:Connect(function() InventoryController.Toggle() end)
	ui.InventoryFrame:WaitForChild("ExitButton").MouseButton1Click:Connect(function() InventoryController.Toggle(false) end)

	ui.SidePopUp:WaitForChild("Open").MouseButton1Click:Connect(function() 
		if state.selectedChest then 
			OpenChestEvent:FireServer(state.selectedChest)
			InventoryController.Toggle(false)
		end 
	end)

	PlayerData.Observe(LocalPlayer, "OwnedChests", function()
		if ui.InventoryFrame.Visible then InventoryController.Refresh() end 
	end)
end

return InventoryController
