local UIController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateGameStateEvent = Events:WaitForChild("UpdateGameState")
--local InventoryToggleIconEvent = Events:WaitForChild("InventoryToggleIconEvent")

local Utils = ReplicatedStorage:WaitForChild("Utils")

local UIInteractionController = require(script.Parent:WaitForChild("UIInteractionController"))
local MobileController = require(script.Parent:WaitForChild("MobileController"))
local NotificationUtil = require(Utils:WaitForChild("NotificationUtil"))

-- ==========================================
-- STATE & VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer :: Player
local ui = {
	statusLabel = nil,
	bagCounterLabel = nil,
	coinsTextLabel = nil,
	cooldownBar = nil,
	abilityBar = nil,
	coinBuffFrame = nil,
	coinBuffText = nil,
}

-- ==========================================
-- UTILS
-- ==========================================
local function formatTime(seconds)
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function FormatNumber(n: number) -- 38699 → "38,699"
	local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

local function toggleFramesByTag(tagName, state, useCameraEffects)
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui") 
	if not playerGui then return end

	for _, frame in ipairs(CollectionService:GetTagged(tagName)) do
		if frame:IsDescendantOf(playerGui) then
			task.spawn(function()
				UIInteractionController.ToggleFrame(frame, state, useCameraEffects)
			end)
		end
	end
end

-- ==========================================
-- UPDATE LOGIC
-- ==========================================
local function updateArenaVisibility()
	local isOnArena = LocalPlayer:GetAttribute("IsOnArena")
	local isInTraining = LocalPlayer:GetAttribute("IsInTrainingArea")
	local isSpectating = LocalPlayer:GetAttribute("IsSpectating")
	local isResultShown = LocalPlayer:GetAttribute("ResultShown")
	local showCombatUI = isOnArena or isInTraining
	local showLobbyPanels = not showCombatUI and not isResultShown

	if isSpectating then
		--InventoryToggleIconEvent:Fire(false)
		UIInteractionController.CloseActiveFrame()
		toggleFramesByTag("LobbyFrame", false, false)
		toggleFramesByTag("ArenaFrame", false, false)

		MobileController:SetVisible(false)
		if ui.cooldownBar then UIInteractionController.ToggleFrame(ui.cooldownBar, false, false) end
		if ui.abilityBar then UIInteractionController.ToggleFrame(ui.abilityBar, false, false) end
		return
	end

	MobileController:SetVisible(true)

	if not showLobbyPanels then 
		--InventoryToggleIconEvent:Fire(false)
		UIInteractionController.CloseActiveFrame()
	end

	if ui.cooldownBar then UIInteractionController.ToggleFrame(ui.cooldownBar, showCombatUI, false) end
	if ui.abilityBar then UIInteractionController.ToggleFrame(ui.abilityBar, showCombatUI, false) end

	toggleFramesByTag("ArenaFrame", showCombatUI, false)
	toggleFramesByTag("LobbyFrame", showLobbyPanels, false)
end

-- ==========================================
-- INIT
-- ==========================================
function UIController.Init()
	local MainGui = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MainGui")
	local HUD = MainGui:WaitForChild("HUD")

	ui.cooldownBar = HUD:WaitForChild("CooldownBar", 5)
	ui.abilityBar = HUD:WaitForChild("AbilityCooldownBar", 5)
	ui.statusLabel = HUD:WaitForChild("GameStatusLabel", 5)
	
	local currenciesFrame = HUD:WaitForChild("CurrencyHolder", 5)
	if currenciesFrame then ui.coinsTextLabel = currenciesFrame:WaitForChild("Value") end

	UpdateGameStateEvent.OnClientEvent:Connect(function(state, timerOrWinner)
		if not ui.statusLabel then return end
		if state == "Waiting" then
			ui.statusLabel.Text = "Waiting for players..."
		elseif state == "Intermission" then
			ui.statusLabel.Text = "Intermission: " .. tostring(timerOrWinner)
		elseif state == "Preparing" then
			ui.statusLabel.Text = "Match starts in: " .. tostring(timerOrWinner)
		elseif state == "Starting" then
			ui.statusLabel.Text = "Get ready!"
		elseif state == "Playing" then
			ui.statusLabel.Text = "Fight! Time left: " .. formatTime(timerOrWinner)
		elseif state == "GameOver" then
			if timerOrWinner then
				NotificationUtil.Show("Success", "🏆 " .. tostring(timerOrWinner.Name) .. " won the match!")
			else
				NotificationUtil.Show("Warning", "⚖️ Match ended in a draw!")
			end
		end
	end)

	local coinBuffFrame = HUD:WaitForChild("CoinBuff", 5) :: Frame
	local coinBuffText = coinBuffFrame:WaitForChild("Value", 5) :: TextLabel
	coinBuffFrame.Visible = false
	LocalPlayer.AttributeChanged:Connect(function(attr)
		if attr == "IsOnArena" or attr == "IsSpectating" or attr == "IsInTrainingArea"or attr == "ResultShown" then
			updateArenaVisibility()
		elseif attr == "BagScore" and ui.bagCounterLabel then
			ui.bagCounterLabel.Text = tostring(LocalPlayer:GetAttribute("BagScore") or 0)
		elseif attr == "Coins" and ui.coinsTextLabel then
			ui.coinsTextLabel.Text = FormatNumber(math.round(tonumber(LocalPlayer:GetAttribute("Coins")) or 0))
		elseif attr == "EquippedAbility" then
			MobileController:SetAbilityIcon(LocalPlayer:GetAttribute("EquippedAbility"))
		elseif attr == "Has2xCoinsBuff" then
			coinBuffFrame.Visible = LocalPlayer:GetAttribute(attr) == true
		end
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			local time_ = workspace:GetServerTimeNow()
			local expiredOn = LocalPlayer:GetAttribute("x2CoinBuffExpiredOn")
			if expiredOn and typeof(expiredOn) == "number" then
				local delta = expiredOn - time_
				if delta > 0 then
					local min = math.floor(delta/60)
					local sec = delta%60
					coinBuffText.Text = string.format("%02d:%02d", min, sec)
				else
					coinBuffText.Text = "00:00"
				end
			end
		end
	end)

	for _, frame in ipairs(CollectionService:GetTagged("ArenaFrame")) do
		frame.Visible = false
	end

	updateArenaVisibility()
	MobileController:SetAbilityIcon(LocalPlayer:GetAttribute("EquippedAbility"))

	if ui.bagCounterLabel then ui.bagCounterLabel.Text = tostring(LocalPlayer:GetAttribute("BagScore") or 0) end
	if ui.coinsTextLabel then ui.coinsTextLabel.Text = FormatNumber(math.round(tonumber(LocalPlayer:GetAttribute("Coins")) or 0)) end
end

return UIController