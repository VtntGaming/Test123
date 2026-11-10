--!nonstrict
-- New-player tutorial (client side).
--
-- Uses the existing MainGui.Panel frame (Step / Message / Skip) - no panel is created from code.
--
-- Flow (starts automatically for new players):
--   1. ATTACK    -> "HOLD to charge, RELEASE to hit"   (only shown while in an arena / the training area)
--   2. ABILITY   -> "use your skill"                   -> the server saves TutorialCompleted and pays the coins
--   3. SHOP      -> arrow to the Merchant (shown once the player is back in the lobby)
--   4. BUY       -> buy a chest in the shop
--   5. OPEN      -> equip the chest and click to open it
--   6. EQUIPMENT -> open the Equipments frame
--   7. ABILITIES -> open the Abilities tab -> tutorial finished
--   Steps 3-7 are guided locally (the coins were already paid in step 2, enough for a Wooden chest).
--
-- Test again in a playtest (Server datamodel, command bar):
--   game.Players.<Name>:SetAttribute("TutorialCompleted", false)

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local Events = ReplicatedStorage:WaitForChild("Events")
local TutorialEvent = Events:WaitForChild("TutorialEvent")
local CombatAttackEvent = Events:WaitForChild("CombatAttack")
local OpenChestEvent = Events:WaitForChild("OpenChestEvent")

--// Constants
local GOLD = Color3.fromRGB(255, 205, 60)
local TOTAL_STEPS = 7
local START_DELAY = 2               -- lets the server's "veteran player" check replicate first
local MIN_CHARGE_HOLD = 0.35        -- seconds the attack must be held to count as "charged"
local CHEST_FALLBACK = 15           -- seconds after opening a chest until we continue even if no weapon arrived
local WEAPON_DELAY = 1.5            -- seconds after the weapon arrived (lets the reveal finish)
local SHOP_CHEST = "Wooden"         -- chest highlighted in the shop (cheapest)

--// Module
local Controller = {}

--// State
local running = false
local loopToken = 0
local connections = {}
local currentKey = nil

local hadZone = false
local attackDone = false
local abilityDone = false
local shopSeen = false
local bought = false
local opened = false
local weaponReady = false
local equipSeen = false
local abilityTabSeen = false
local finishing = false
local toolBaseline = 0
local holdStart = nil

-- UI (all of it already exists in StarterGui.MainGui)
local mainGui, panel, panelScale, panelBaseScale, stepLabel, messageLabel, skipButton, phoneButtons
local shopFrame, equipFrame, equipmentsButton, abilitiesTab
local pulses = {}
local arrowGui, arrowTween

-- forward declarations
local evaluate, stop, finish

--// Helpers
local function track(connection)
	table.insert(connections, connection)
	return connection
end

local function isTouch()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function inCombatZone()
	return LocalPlayer:GetAttribute("IsOnArena") == true or LocalPlayer:GetAttribute("IsInTrainingArea") == true
end

local function toolCount()
	local count = 0
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") then count += 1 end
		end
	end
	local character = LocalPlayer.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then count += 1 end
		end
	end
	return count
end

local function getShopTrigger()
	for _, tagged in ipairs(CollectionService:GetTagged("ShopTrigger")) do
		if tagged:IsA("BasePart") then return tagged end
	end
	return nil
end

--// Step definitions
local STEPS = {
	Fight_Ready = {
		Index = 1,
		Text = function()
			return "Get ready!"
		end,
	},
	Fight = {
		Index = 1,
		Text = function()
			if isTouch() then
				return "HOLD YOUR ATTACK!"
			end
			return "HOLD YOUR ATTACK!"
		end,
	},
	Ability = {
		Index = 2,
		Text = function()
			if isTouch() then
				return "USE YOUR ABILITY!"
			end
			return "USE YOUR ABILITY! [RIGHT CLICK]"
		end,
	},
	Post_Wait = {
		Index = 3,
		Text = function()
			return "Good"
		end,
	},
	Shop_Go = {
		Index = 3,
		Text = function()
			return "GO TO THE Merchant!"
		end,
	},
	Shop_Buy = {
		Index = 4,
		Text = function()
			return ("Buy a %s chest!"):format(string.upper(SHOP_CHEST))
		end,
	},
	Chest_Open = {
		Index = 5,
		Text = function()
			if isTouch() then
				return "OPEN YOUR CHEST!"
			end
			return "OPEN YOUR CHEST!"
		end,
	},
	Equip_Open = {
		Index = 6,
		Text = function()
			return "OPEN EQUIPMENT FRAME!"
		end,
	},
	Ability_Tab = {
		Index = 7,
		Text = function()
			return "OPEN ABILITIES FRAME!"
		end,
	},
}

--// UI: existing MainGui.Panel
local function popPanel()
	if not panelScale then return end
	panelScale.Scale = panelBaseScale * 0.9
	TweenService:Create(panelScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = panelBaseScale,
	}):Play()
end

local function hidePanel()
	if panel then panel.Visible = false end
end

local function setPrompt(label, text)
	stepLabel.Text = label
	messageLabel.Text = text
	panel.Visible = true
	popPanel()
end

--// UI: pulse a button / frame (reuses its UIStroke, or adds a temporary one)
local function clearPulses()
	for _, entry in ipairs(pulses) do
		entry.tween:Cancel()
		if entry.stroke.Parent then
			if entry.created then
				entry.stroke:Destroy()
			else
				entry.stroke.Color = entry.color
				entry.stroke.Thickness = entry.thickness
			end
		end
	end
	table.clear(pulses)
end

local function pulseObject(object)
	if not object then return end
	local stroke = object:FindFirstChild("Outer") or object:FindFirstChildOfClass("UIStroke")
	local created = false
	if not (stroke and stroke:IsA("UIStroke")) then
		if not object:IsA("GuiObject") then return end
		stroke = Instance.new("UIStroke")
		stroke.Name = "TutorialPulse"
		stroke.Thickness = 2
		stroke.Parent = object
		created = true
	end

	local entry = { stroke = stroke, color = stroke.Color, thickness = stroke.Thickness, created = created }
	stroke.Color = GOLD
	entry.tween = TweenService:Create(
		stroke,
		TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Thickness = entry.thickness + 5 }
	)
	entry.tween:Play()
	table.insert(pulses, entry)
end

--// World: bobbing arrow above the shop
local function clearArrow()
	if arrowTween then
		arrowTween:Cancel()
		arrowTween = nil
	end
	if arrowGui then
		arrowGui:Destroy()
		arrowGui = nil
	end
end

local function showArrow(target)
	if not target or not target.Parent then
		clearArrow()
		return
	end
	if arrowGui and arrowGui.Adornee == target then return end
	clearArrow()

	local gui = Instance.new("BillboardGui")
	gui.Name = "TutorialArrow"
	gui.Adornee = target
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(120, 130)
	gui.StudsOffset = Vector3.new(0, 5, 0)
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Parent = target

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 34)
	title.Font = Enum.Font.GothamBlack
	title.Text = "SHOP"
	title.TextScaled = true
	title.TextColor3 = GOLD
	title.Parent = gui
	local titleStroke = Instance.new("UIStroke")
	titleStroke.Thickness = 3
	titleStroke.Color = Color3.new(0, 0, 0)
	titleStroke.Parent = title

	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.BackgroundTransparency = 1
	arrow.Position = UDim2.fromOffset(0, 36)
	arrow.Size = UDim2.new(1, 0, 0, 80)
	arrow.Font = Enum.Font.GothamBlack
	arrow.Text = "\u{25BC}"
	arrow.TextScaled = true
	arrow.TextColor3 = GOLD
	arrow.Parent = gui
	local arrowStroke = Instance.new("UIStroke")
	arrowStroke.Thickness = 3
	arrowStroke.Color = Color3.new(0, 0, 0)
	arrowStroke.Parent = arrow

	arrowTween = TweenService:Create(
		arrow,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = UDim2.fromOffset(0, 54) }
	)
	arrowTween:Play()
	arrowGui = gui
end

--// Step logic
local function applyStep(key)
	currentKey = key
	clearPulses()

	if key ~= "Shop_Go" then
		clearArrow()
	end

	local def = STEPS[key]
	if not def then
		hidePanel()
		return
	end

	setPrompt(("STEP %d / %d"):format(def.Index, TOTAL_STEPS), def.Text())

	if key == "Shop_Go" then
		showArrow(getShopTrigger())
	elseif key == "Shop_Buy" then
		local function pulseChest()
			local list = shopFrame and shopFrame:FindFirstChild("ScrollHolder") and shopFrame.ScrollHolder:FindFirstChild("ScrollingFrame")
			pulseObject(list and list:FindFirstChild(SHOP_CHEST))
		end
		pulseChest()
		-- the chest cards are created the moment the shop opens: retry once if they were not there yet
		task.delay(0.6, function()
			if running and currentKey == "Shop_Buy" and #pulses == 0 then pulseChest() end
		end)
	elseif key == "Equip_Open" then
		pulseObject(equipmentsButton)
	elseif key == "Ability_Tab" then
		pulseObject(abilitiesTab)
	elseif isTouch() and phoneButtons then
		if key == "Fight" then
			pulseObject(phoneButtons:FindFirstChild("AttackButton"))
		elseif key == "Ability" then
			pulseObject(phoneButtons:FindFirstChild("AbilityButton"))
		end
	end
end

local function computeKey(inZone)
	-- Part 1: fight steps (arena or training area)
	if not abilityDone then
		if not inZone then return "Hidden" end
		if LocalPlayer:GetAttribute("IsOnArena") == true then
			local matchState = ReplicatedStorage:GetAttribute("MatchState")
			if matchState == "GameOver" then return "Hidden" end
			if not attackDone then
				return if matchState == "Playing" then "Fight" else "Fight_Ready"
			end
			return "Ability"
		end
		return if attackDone then "Ability" else "Fight"
	end

	-- Part 2: shop steps (lobby)
	if inZone then return "Post_Wait" end

	if not shopSeen then
		if shopFrame and shopFrame.Visible then
			shopSeen = true
			toolBaseline = toolCount()
		else
			return "Shop_Go"
		end
	end

	if not bought then
		if toolCount() > toolBaseline then
			bought = true
		elseif shopFrame and shopFrame.Visible then
			return "Shop_Buy"
		else
			return "Shop_Go"
		end
	end

	if not opened then return "Chest_Open" end
	if not weaponReady then return "Hidden" end -- keep the screen clear during the chest animation

	if not equipSeen then
		if equipFrame and equipFrame.Visible then
			equipSeen = true
		else
			return "Equip_Open"
		end
	end

	if not abilityTabSeen then return "Ability_Tab" end
	return "Done"
end

evaluate = function()
	if not running or finishing then return end

	local inZone = inCombatZone()
	if not abilityDone then
		if inZone then
			hadZone = true
		elseif hadZone then
			-- left the arena / training area before the fight steps were done: start over next time
			hadZone = false
			attackDone = false
			holdStart = nil
			currentKey = nil
		end
	end

	local key = computeKey(inZone)
	if key == "Done" then
		finish()
		return
	end
	if key ~= currentKey then
		applyStep(key)
	end
end

finish = function()
	if finishing then return end
	finishing = true
	currentKey = "Finish"

	clearPulses()
	clearArrow()
	hidePanel()
	pcall(function()
		require(ReplicatedStorage.Utils.NotificationUtil).Show("Success", "Tutorial complete! Good luck!")
	end)
	stop()
end

stop = function()
	if not running then return end
	running = false
	loopToken += 1

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	clearPulses()
	clearArrow()
	hidePanel()
	currentKey = nil
	holdStart = nil
end

--// Input tracking
local function onAttackBegan()
	if currentKey == "Fight" then
		holdStart = os.clock()
	end
end

local function onAttackEnded()
	local started = holdStart
	holdStart = nil
	if started and currentKey == "Fight" and os.clock() - started >= MIN_CHARGE_HOLD then
		attackDone = true
		evaluate()
	end
end

local function onAbilityUsed()
	if currentKey ~= "Ability" then return end
	abilityDone = true
	-- the server pays the coins (enough for a chest) and saves TutorialCompleted
	TutorialEvent:FireServer("CombatDone")
	evaluate()
end

local function isPointerInput(input)
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
end

local function connectEvents()
	-- A landed hit also counts as "attack done" (same remote CombatController listens to).
	track(CombatAttackEvent.OnClientEvent:Connect(function(action, _, actor, _, _, hits)
		if action == "Hits" and actor == LocalPlayer.Character and type(hits) == "table" and #hits > 0 then
			if currentKey == "Fight" then
				attackDone = true
				evaluate()
			end
		end
	end))

	-- PC: left click hold/release, right click ability.
	track(UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			onAttackBegan()
		elseif input.KeyCode == Enum.KeyCode.E then
			onAbilityUsed()
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			onAttackEnded()
		end
	end))

	-- Mobile: same buttons CombatController binds.
	local attackButton = phoneButtons and phoneButtons:FindFirstChild("AttackButton")
	if attackButton then
		for _, item in ipairs(attackButton:GetChildren()) do
			if item:IsA("GuiButton") then
				track(item.InputBegan:Connect(function(input)
					if isPointerInput(input) then onAttackBegan() end
				end))
				track(item.InputEnded:Connect(function(input)
					if isPointerInput(input) then onAttackEnded() end
				end))
			end
		end
	end
	local abilityButton = phoneButtons and phoneButtons:FindFirstChild("AbilityButton")
	if abilityButton then
		for _, item in ipairs(abilityButton:GetChildren()) do
			if item:IsA("GuiButton") then
				track(item.InputBegan:Connect(function(input)
					if isPointerInput(input) then onAbilityUsed() end
				end))
			end
		end
	end

	-- Chest steps
	track(OpenChestEvent.OnClientEvent:Connect(function(opener)
		if opener ~= LocalPlayer or not abilityDone or opened then return end
		opened, bought, shopSeen = true, true, true
		task.delay(CHEST_FALLBACK, function()
			if running then
				weaponReady = true
				evaluate()
			end
		end)
		evaluate()
	end))
	track(LocalPlayer:GetAttributeChangedSignal("OwnedWeapons"):Connect(function()
		if opened and not weaponReady then
			task.delay(WEAPON_DELAY, function()
				if running then
					weaponReady = true
					evaluate()
				end
			end)
		end
	end))
	track(LocalPlayer:GetAttributeChangedSignal("OwnedChests"):Connect(function()
		if abilityDone and shopSeen and not bought then
			bought = true
			evaluate()
		end
	end))

	track(LocalPlayer:GetAttributeChangedSignal("IsOnArena"):Connect(evaluate))
	track(LocalPlayer:GetAttributeChangedSignal("IsInTrainingArea"):Connect(evaluate))
	track(ReplicatedStorage:GetAttributeChangedSignal("MatchState"):Connect(evaluate))
end

local function start()
	if running then return end
	running = true
	finishing = false
	hadZone, attackDone, abilityDone = false, false, false
	shopSeen, bought, opened, weaponReady, equipSeen, abilityTabSeen = false, false, false, false, false, false
	toolBaseline = 0
	holdStart = nil
	currentKey = nil
	loopToken += 1
	local token = loopToken

	connectEvents()

	task.spawn(function()
		while running and token == loopToken do
			evaluate()
			task.wait(0.2)
		end
	end)
end

local function tryStart()
	if running or not panel then return end
	if LocalPlayer:GetAttribute("DataLoaded") ~= true then return end
	if LocalPlayer:GetAttribute("TutorialCompleted") == true then return end
	start()
end

--// Server messages
local function onServerEvent(action, amount)
	if action == "Reward" then
		if type(amount) == "number" and amount > 0 then
			pcall(function()
				require(ReplicatedStorage.Utils.NotificationUtil).Show("Success", ("+%d coins! Spend them in the shop."):format(amount))
			end)
		end
	elseif action == "Done" then
		stop()
	end
end

--// Existing UI the shop steps point at
local function resolveRefs()
	shopFrame = mainGui:WaitForChild("ShopFrame", 10)
	equipFrame = mainGui:WaitForChild("EquipmentsFrame", 10)

	local hud = mainGui:FindFirstChild("HUD")
	equipmentsButton = hud and hud:FindFirstChild("EquipmentsButton", true)

	local tabs = equipFrame and equipFrame:FindFirstChild("TabHolder")
	abilitiesTab = tabs and tabs:FindFirstChild("Abilities")
	if abilitiesTab and abilitiesTab:IsA("GuiButton") then
		abilitiesTab.Activated:Connect(function()
			if running and abilityDone and weaponReady then
				abilityTabSeen = true
				evaluate()
			end
		end)
	end
end

--// Bind to the Panel that already exists in MainGui
local function bindPanel()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	mainGui = playerGui:WaitForChild("MainGui")
	phoneButtons = mainGui:FindFirstChild("PhoneButtons")
	panel = mainGui:WaitForChild("Panel")
	stepLabel = panel:WaitForChild("Step")
	messageLabel = panel:WaitForChild("Message")
	skipButton = panel:WaitForChild("Skip")
	panelScale = panel:FindFirstChildOfClass("UIScale")
	panelBaseScale = panelScale and panelScale.Scale or 1

	panel.Visible = false
	skipButton.Activated:Connect(function()
		if abilityDone then
			-- the server already saved the tutorial: skipping the shop steps is local only
			finish()
		else
			TutorialEvent:FireServer("Skip")
		end
	end)

	task.spawn(resolveRefs)
end

function Controller.Init()
	TutorialEvent.OnClientEvent:Connect(onServerEvent)

	LocalPlayer:GetAttributeChangedSignal("TutorialCompleted"):Connect(function()
		if LocalPlayer:GetAttribute("TutorialCompleted") == true then
			-- the server sets it right after the ability step: the shop steps keep running
			if not abilityDone then stop() end
		else
			task.delay(START_DELAY, tryStart)
		end
	end)

	task.spawn(function()
		bindPanel()
		while LocalPlayer:GetAttribute("DataLoaded") ~= true do
			task.wait(0.25)
		end
		task.wait(START_DELAY)
		tryStart()
	end)
end

return Controller
