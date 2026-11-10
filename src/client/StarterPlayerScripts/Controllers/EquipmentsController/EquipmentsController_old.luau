--[[
```luau
local EquipmentsController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local UIInteractionController = require(script.Parent:WaitForChild("UIInteractionController"))
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))
local AbilityConfig = require(SharedModules:WaitForChild("AbilityConfig"))

-- ==========================================
-- VARIABLES & CONSTANTS
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local Events = ReplicatedStorage:WaitForChild("Events")
local EquipWeaponEvent = Events:WaitForChild("EquipWeaponEvent")
local EquipAbilityEvent = Events:FindFirstChild("EquipAbilityEvent") or Events:WaitForChild("DevEquipAbilityEvent") 

local RARITY_ORDER = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
local TAB_ACTIVE, TAB_INACTIVE, EQUIPPED_IMG = "rbxassetid://72940564227520", "rbxassetid://85490089980863", "rbxassetid://85490089980863"

local ABILITY_ICONS = {
	MegaJump = "rbxassetid://78794119577901",
	Shrink = "rbxassetid://125873903836357",
	Dash = "rbxassetid://88569411185376",
	Invisible = "rbxassetid://121839492367614"
}

local ui, state = {}, { isOpen = false, filter = "Slap", currentTab = "Weapons", items = {}, titles = {}, selected = nil, defaultEquipImg = "" }

-- ==========================================
-- UTILS
-- ==========================================
local function formatNum(n) return tostring(n):reverse():gsub("%d%d%d", "%1."):reverse():gsub("^%.", "") end
local function getOwnedCount(name, isAbility) local c = 0; for _, v in ipairs(string.split(PlayerData.Get(LocalPlayer, isAbility and "OwnedAbilities" or "OwnedWeapons") or "", ",")) do if v == name then c += 1 end end; return c > 0 and c or (isAbility and 1 or 0) end

local function updateEquipVisuals()
	if not state.selected then return end
	local isEq = (state.currentTab == "Weapons" and PlayerData.Get(LocalPlayer, "EquippedWeapon") == state.selected) or (state.currentTab == "Abilities" and PlayerData.Get(LocalPlayer, "EquippedAbility") == state.selected)
	ui.equip.Image = isEq and EQUIPPED_IMG or state.defaultEquipImg
	local eqTitle = ui.equip:FindFirstChild("Title"); if eqTitle then eqTitle.Text = isEq and "EQUIPPED" or "EQUIP" end
end

-- ==========================================
-- CORE LOGIC
-- ==========================================
local function togglePopUp(itemName, info, isOwned, count)
	if state.selected == itemName then
		UIInteractionController.ToggleFrame(ui.popup, false, false); state.selected = nil
	else
		state.selected = itemName
		ui.popup.Title.Text = isOwned and info.DisplayName or "???"
		ui.popup.RarityLabel.Text = isOwned and info.Rarity or "Unknown"
		ui.popup.RarityLabel.TextColor3 = isOwned and info.RarityColor or Color3.fromRGB(100, 100, 100)

		if state.currentTab == "Weapons" then
			ui.popup.ChanceLabel.Text = string.format('<font color="#4ADE80">OWNED:</font> <font color="#FFFFFF">X%d</font>\n<font color="#22D3EE">EXISTING:</font> <font color="#FFFFFF">%s</font>', count, formatNum(ReplicatedValues.GetNumber(ReplicatedStorage, "Existing_" .. info.FullName) or 0))
		else
			ui.popup.ChanceLabel.Text = string.format('<font color="#4ADE80">OWNED:</font> <font color="#FFFFFF">X%d</font>', count)
		end

		if info.Icon and info.Icon ~= "" then ui.popup.Icon.Image = info.Icon; ui.popup.Icon.ImageTransparency = 0; ui.popup.Icon.ImageColor3 = isOwned and Color3.new(1, 1, 1) or Color3.new(0, 0, 0) else ui.popup.Icon.Image = ""; ui.popup.Icon.ImageTransparency = 1 end

		ui.equip.Visible = isOwned; updateEquipVisuals()
		UIInteractionController.ToggleFrame(ui.popup, true, false)
	end
end

local function populateList()
	for _, v in pairs(state.items) do v.Visible = false end
	for _, v in pairs(state.titles) do v.Visible = false end

	if state.currentTab == "Weapons" then
		local groups = { Common = {state.filter}, Rare = {}, Epic = {}, Legendary = {}, Mythic = {} }
		for r, vars in pairs(WeaponConfig.RarityVariants) do for _, v in ipairs(vars) do table.insert(groups[r], state.filter .. v) end end

		local layoutOrder = 0
		for _, r in ipairs(RARITY_ORDER) do
			if #groups[r] == 0 then continue end
			layoutOrder += 1

			local title = state.titles[r] or ui.rarityTemplate:Clone()
			if not state.titles[r] then title.Name, title.Parent, state.titles[r] = r, ui.scroll, title; local txt = title:FindFirstChild("Title"); if txt then txt.Text, txt.TextColor3 = r, WeaponConfig.Rarities[r] end end
			title.LayoutOrder, title.Visible = layoutOrder * 100, true

			for i, wName in ipairs(groups[r]) do
				local count = getOwnedCount(wName, false); local isOwned, info = count > 0, WeaponConfig.GetWeaponInfo(wName)
				if not info then continue end

				local item = state.items[wName] or ui.itemTemplate:Clone()
				if not state.items[wName] then item.Name, item.Parent, state.items[wName] = wName, ui.scroll, item; local txt = item:FindFirstChild("Title"); if txt then txt.Text = info.DisplayName end; if item:IsA("GuiButton") then item.MouseButton1Click:Connect(function() togglePopUp(wName, info, getOwnedCount(wName, false) > 0, getOwnedCount(wName, false)) end) end end
				item.LayoutOrder, item.Visible = (layoutOrder * 100) + i, true

				local icon = item:FindFirstChild("Icon")
				if icon then if info.Icon and info.Icon ~= "" then icon.Image = info.Icon; icon.ImageTransparency = 0; icon.ImageColor3 = isOwned and Color3.new(1, 1, 1) or Color3.new(0, 0, 0) else icon.Image = ""; icon.ImageTransparency = 1 end end
			end
		end
	else
		local i = 0
		for aName, _ in pairs(AbilityConfig.Abilities) do
			if aName == "SpawnInvulnerability" then continue end
			i += 1

			local count = getOwnedCount(aName, true); local isOwned = count > 0
			local info = { FullName = aName, DisplayName = aName, BaseName = aName, Rarity = "Ability", RarityColor = Color3.fromRGB(150, 150, 255), Icon = ABILITY_ICONS[aName] or "" }

			local item = state.items[aName] or ui.itemTemplate:Clone()
			if not state.items[aName] then item.Name, item.Parent, state.items[aName] = aName, ui.scroll, item; local txt = item:FindFirstChild("Title"); if txt then txt.Text = info.DisplayName end; if item:IsA("GuiButton") then item.MouseButton1Click:Connect(function() togglePopUp(aName, info, getOwnedCount(aName, true) > 0, getOwnedCount(aName, true)) end) end end
			item.LayoutOrder, item.Visible = i, true

			local icon = item:FindFirstChild("Icon")
			if icon then if info.Icon and info.Icon ~= "" then icon.Image = info.Icon; icon.ImageTransparency = 0; icon.ImageColor3 = isOwned and Color3.new(1, 1, 1) or Color3.new(0, 0, 0) else icon.Image = ""; icon.ImageTransparency = 1 end end
		end
	end

	if state.selected then
		local c = getOwnedCount(state.selected, state.currentTab == "Abilities")
		if c == 0 then UIInteractionController.ToggleFrame(ui.popup, false, false); state.selected = nil else togglePopUp(state.selected, state.currentTab == "Weapons" and WeaponConfig.GetWeaponInfo(state.selected) or {FullName = state.selected, DisplayName = state.selected, Rarity = "Ability", RarityColor = Color3.fromRGB(150, 150, 255), Icon = ABILITY_ICONS[state.selected]}, true, c) end
	end
end

local function switchTab(tabName)
	state.currentTab = tabName
	ui.wpnTabBtn.Image = tabName == "Weapons" and TAB_ACTIVE or TAB_INACTIVE
	ui.abilityTabBtn.Image = tabName == "Abilities" and TAB_ACTIVE or TAB_INACTIVE
	ui.filters.Visible = tabName == "Weapons"

	UIInteractionController.ToggleFrame(ui.popup, false, false); state.selected = nil
	populateList()

	if tabName == "Abilities" then ui.scroll.CanvasPosition = Vector2.new(0, 0) end
end

-- ==========================================
-- INIT
-- ==========================================
function EquipmentsController.Init()
	local MainGui = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MainGui")

	ui.btn = MainGui:WaitForChild("HUD"):WaitForChild("LeftButtons"):WaitForChild("ButtonList"):WaitForChild("EquipmentsButton")
	ui.frame = MainGui:WaitForChild("EquipmentsFrame")
	ui.filters = ui.frame:WaitForChild("ButtonsHolder")
	ui.scroll = ui.frame:WaitForChild("ScrollHolder"):WaitForChild("ScrollingFrame")
	ui.popup = ui.frame:WaitForChild("SidePopUp")
	ui.equip = ui.popup:WaitForChild("Equip")

	local tabs = ui.frame:WaitForChild("TabHolder")
	ui.wpnTabBtn = tabs:WaitForChild("Weapons")
	ui.abilityTabBtn = tabs:WaitForChild("Abilities")

	CollectionService:AddTag(ui.popup, "PopUpFrame")
	state.defaultEquipImg = ui.equip.Image
	ui.popup.ChanceLabel.RichText = true; ui.popup.Visible = false

	ui.rarityTemplate = ui.scroll:WaitForChild("RarityTitle"); ui.rarityTemplate.Visible = false
	ui.itemTemplate = ui.scroll:WaitForChild("Template"); ui.itemTemplate.Visible = false

	local clickTarget = ui.btn:FindFirstChildOfClass("ImageButton") or ui.btn
	clickTarget.MouseButton1Click:Connect(function()
		state.isOpen = not state.isOpen
		if not state.isOpen then UIInteractionController.ToggleFrame(ui.popup, false, false); state.selected = nil end
		UIInteractionController.ToggleFrame(ui.frame, state.isOpen)
		if state.isOpen then switchTab("Weapons") end
	end)

	ui.frame:WaitForChild("ExitButton").MouseButton1Click:Connect(function() state.isOpen = false; UIInteractionController.ToggleFrame(ui.frame, false); UIInteractionController.ToggleFrame(ui.popup, false, false); state.selected = nil end)

	ui.wpnTabBtn.MouseButton1Click:Connect(function() switchTab("Weapons") end)
	ui.abilityTabBtn.MouseButton1Click:Connect(function() switchTab("Abilities") end)

	for _, fBtn in ipairs(ui.filters:GetChildren()) do
		if fBtn:IsA("GuiButton") then fBtn.MouseButton1Click:Connect(function() state.filter = string.gsub(fBtn.Name, "Button", ""); UIInteractionController.ToggleFrame(ui.popup, false, false); state.selected = nil; populateList() end) end
	end

	ui.equip.MouseButton1Click:Connect(function()
		if state.selected then 
			if state.currentTab == "Weapons" then EquipWeaponEvent:FireServer(state.selected) else EquipAbilityEvent:FireServer(state.selected) end
			-- L'aggiornamento visivo è ora gestito in automatico dagli AttributeChangedSignal
		end
	end)

	PlayerData.Observe(LocalPlayer, "OwnedWeapons", function() if ui.frame.Visible and state.currentTab == "Weapons" then populateList() end end)
	PlayerData.Observe(LocalPlayer, "OwnedAbilities", function() if ui.frame.Visible and state.currentTab == "Abilities" then populateList() end end)

	PlayerData.Observe(LocalPlayer, "EquippedWeapon", updateEquipVisuals)
	PlayerData.Observe(LocalPlayer, "EquippedAbility", updateEquipVisuals)

	ReplicatedValues.GetAllChangedSignal(ReplicatedStorage):Connect(function(attr)
		if state.selected and state.currentTab == "Weapons" and attr == ("Existing_" .. state.selected) then
			ui.popup.ChanceLabel.Text = string.format('<font color="#4ADE80">OWNED:</font> <font color="#FFFFFF">X%d</font>\n<font color="#22D3EE">EXISTING:</font> <font color="#FFFFFF">%s</font>', getOwnedCount(state.selected, false), formatNum(ReplicatedValues.GetNumber(ReplicatedStorage, attr) or 0))
		end
	end)
end

return EquipmentsController
```
]]
