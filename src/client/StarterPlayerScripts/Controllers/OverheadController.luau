-- Owns player overhead content and resolves combat and invisibility visibility together.
local OverheadController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PlayerData = require(ReplicatedStorage.PlayerData)
local RobuxShopConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("RobuxShopConfig"))
-- Keeps one live overhead per source actor; visual rigs temporarily own its adornment target.
local VisualRig = require(script.Parent.RagdollController.VisualRig)
local PassesConfig = RobuxShopConfig.Passes

-- ==========================================
-- VARIABLES & CONFIG
-- ==========================================
local Assets = ReplicatedStorage:WaitForChild("Assets")
local Overheads = Assets:WaitForChild("Overheads")
local OverheadHeartsGuiTemplate = Overheads:WaitForChild("OverheadHeartsGui")
local OverheadUsernameGuiTemplate = Overheads:WaitForChild("OverheadUsernameGui")

local MAX_LIVES = 3
local GROUP_ID = 33988452 

local ROLE_COLORS = {
	["Member"] = "#3CFF00"
}

local HARDWARE_ICONS = {
	["Controller"] = "rbxassetid://72973314898936",
	["Mobile"] = "rbxassetid://118357127629338",
	["PC"] = "rbxassetid://103495637950753"
}

local heartTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local textTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local heightTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local cachedRoles = {}
local trackedAttributes = { ["Invisible"]=true, ["Lives"]=true, ["Wins"]=true, ["IsOnArena"]=true, ["IsInTrainingArea"]=true, ["IsAFK"]=true, ["Hardware"]=true, [PassesConfig.VIP.Attribute] = true }

type GuiState = {
	Defaults: { [Instance]: { [string]: number } },
	Tweens: { [Instance]: Tween },
	WinsThread: thread?,
	Combat: boolean?,
}
local GuiStates: { [BillboardGui]: GuiState } = {}
local INVISIBLE_TWEEN = TweenInfo.new(0.375, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function PrepareGui(gui: BillboardGui)
	-- Set ownership before parenting, so InvisibleEffect never captures these descendants.
	gui:SetAttribute("OverheadVisibilityManaged", true)
	local state: GuiState = { Defaults = {}, Tweens = {}, WinsThread = nil, Combat = nil }
	GuiStates[gui] = state
	for _, item in gui:GetDescendants() do
		local defaults: { [string]: number } = {}
		if item:IsA("GuiObject") then defaults.BackgroundTransparency = item.BackgroundTransparency end
		if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
			defaults.TextTransparency, defaults.TextStrokeTransparency = item.TextTransparency, item.TextStrokeTransparency
		end
		if item:IsA("ImageLabel") or item:IsA("ImageButton") then defaults.ImageTransparency = item.ImageTransparency end
		if item:IsA("UIStroke") then defaults.Transparency = item.Transparency end
		if item:IsA("ScrollingFrame") then defaults.ScrollBarImageTransparency = item.ScrollBarImageTransparency end
		if item:IsA("CanvasGroup") then defaults.GroupTransparency = item.GroupTransparency end
		if next(defaults) then state.Defaults[item] = defaults end
	end
	gui.Destroying:Connect(function()
		GuiStates[gui] = nil
		if state.WinsThread then task.cancel(state.WinsThread)
state.WinsThread = nil end
		for _, tween in state.Tweens do tween:Cancel()
tween:Destroy() end
		table.clear(state.Tweens)
		table.clear(state.Defaults)
	end)
end

local function UpdateTransparency(player: Player, gui: BillboardGui)
	local state = GuiStates[gui]
	if not state then return end
	local invisible = PlayerData.Get(player, "Invisible") == true
	local combat = PlayerData.Get(player, "IsOnArena") or PlayerData.Get(player, "IsInTrainingArea")
	local wins = gui:FindFirstChild("Wins")
	local lives = PlayerData.Get(player, "Lives") or MAX_LIVES
	for item, defaults in state.Defaults do
		if not item:IsDescendantOf(gui) then continue end
		local goals = table.clone(defaults)
		local heartIndex = tonumber(string.match(item.Name, "^Heart_(%d+)$"))
		if heartIndex and goals.ImageTransparency ~= nil then
			goals.ImageTransparency = if heartIndex <= lives then 0 else 0.65
		end
		if wins and item:IsDescendantOf(wins) then
			-- Preserve the existing lobby appearance even if the template starts faded out.
			if goals.TextTransparency ~= nil then goals.TextTransparency = 0 end
			if goals.TextStrokeTransparency ~= nil then goals.TextStrokeTransparency = 0 end
			if item:IsA("UIStroke") then goals.Transparency = 0 end
		end
		-- Invisibility takes precedence, while combat affects only the Wins contents.
		if invisible or (combat and wins and item:IsDescendantOf(wins)) then
			for property in goals do goals[property] = 1 end
		end
		local old = state.Tweens[item]
		if old then old:Cancel()
old:Destroy() end
		local tween = TweenService:Create(item, if invisible then INVISIBLE_TWEEN else textTweenInfo, goals)
		state.Tweens[item] = tween
		tween:Play()
	end
end

-- ==========================================
-- UI UPDATE LOGIC
-- ==========================================
local function updateHearts(player, gui)
	local currentLives = PlayerData.Get(player, "Lives") or MAX_LIVES
	for i = 1, MAX_LIVES do
		local heart = gui:FindFirstChild("Heart_" .. i)
		if heart then
			local isAlive = (i <= currentLives)
			TweenService:Create(heart, heartTweenInfo, {
				ImageColor3 = isAlive and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(30, 30, 30)
			}):Play()
		end
	end
end

local function updateCombatState(player, gui)
	local isCombat = PlayerData.Get(player, "IsOnArena") == true or PlayerData.Get(player, "IsInTrainingArea") == true
	
	local winsFrame = gui:FindFirstChild("Wins") :: Frame
	if not winsFrame then
		return
	end
	local state = GuiStates[gui]
	if not state or state.Combat == isCombat then return end
	state.Combat = isCombat
	if state.WinsThread then task.cancel(state.WinsThread)
state.WinsThread = nil end
	if not isCombat then
		winsFrame.Visible = true -- Reveal the frame before fading its contents back in.
		return
	end
	state.WinsThread = task.delay(textTweenInfo.Time, function()
		state.WinsThread = nil
		if GuiStates[gui] == state and gui.Parent and winsFrame.Parent and state.Combat then
			winsFrame.Visible = false
		end
	end)
end

local function updateHeights(player, usernameGui)
	local inArena = PlayerData.Get(player, "IsOnArena")
	local isCombat = inArena or PlayerData.Get(player, "IsInTrainingArea")

	if not usernameGui:GetAttribute("OrigStudsY") then
		usernameGui:SetAttribute("OrigStudsY", usernameGui.StudsOffset.Y)
	end

	local totalReduction = (inArena and 0 or 1.2) + (isCombat and 0.6 or 0)

	TweenService:Create(usernameGui, heightTweenInfo, {StudsOffset = Vector3.new(0, usernameGui:GetAttribute("OrigStudsY") - totalReduction, 0)}):Play()
end

local function updateAllStates(player)
	local head = player.Character and player.Character:FindFirstChild("Head")
	if not head then return end

	local heartsGui = head:FindFirstChild("OverheadHeartsGui")
	local usernameGui = head:FindFirstChild("OverheadUsernameGui")
	
	if heartsGui then
		updateHearts(player, heartsGui)
		heartsGui.Enabled = (PlayerData.Get(player, "IsOnArena") == true)
	end

	local afkText = if usernameGui then usernameGui:FindFirstChild("AFKText") :: TextLabel else nil
	if usernameGui then
		local winsText = usernameGui:FindFirstChild("WinsText", true)
		if winsText then
			winsText.Text = tostring(PlayerData.Get(player, "Wins") or 0)
		end

		updateCombatState(player, usernameGui)

		local hwIcon = usernameGui:FindFirstChild("HardwareIcon", true)
		if hwIcon then
			hwIcon.Image = HARDWARE_ICONS[PlayerData.Get(player, "Hardware") or "PC"] or HARDWARE_ICONS["PC"]
		end
	end

	local vipText = if usernameGui then usernameGui:FindFirstChild("VIP") :: TextLabel else nil

	if vipText then
		vipText.Visible = PlayerData.Get(player, PassesConfig.VIP.Attribute) == true
	end
	if afkText then
		afkText.Visible = (PlayerData.Get(player, "IsAFK") == true)
	end
	if usernameGui then updateHeights(player, usernameGui) end
	if heartsGui then UpdateTransparency(player, heartsGui) end
	if usernameGui then UpdateTransparency(player, usernameGui) end
end

-- ==========================================
-- OVERHEAD MASTER SETUP
-- ==========================================
local function setupOverhead(player, character)
	local head = character:WaitForChild("Head")
	if not head or not head.Parent or not character.Parent then return end

	for _, name in ipairs({"OverheadHeartsGui", "OverheadUsernameGui"}) do
		local old = head:FindFirstChild(name)
		if old then old:Destroy() end
	end

	local heartsGui = OverheadHeartsGuiTemplate:Clone()
	heartsGui.Name = "OverheadHeartsGui"
	heartsGui.Adornee = head
	VisualRig.Adorn(character, heartsGui, head)

	local temp = heartsGui:WaitForChild("HeartTemp")
	temp.Visible = false
	for i = 1, MAX_LIVES do
		local heart = temp:Clone()
		heart.Name = "Heart_" .. i
		heart.Visible = true
		heart.Parent = heartsGui
	end
	PrepareGui(heartsGui)
	heartsGui.Parent = head

	local usernameGui = OverheadUsernameGuiTemplate:Clone()
	usernameGui.Name = "OverheadUsernameGui"
	usernameGui.Adornee = head
	VisualRig.Adorn(character, usernameGui, head)
	PrepareGui(usernameGui)
	usernameGui.Parent = head

	local usernameLabel = usernameGui:FindFirstChild("PlayerUsernameText", true)
	if usernameLabel then
		usernameLabel.RichText = true
		task.spawn(function()
			if cachedRoles[player.UserId] == nil then
				local success, isInGroup = pcall(function() return player:IsInGroup(GROUP_ID) end)
				cachedRoles[player.UserId] = (success and isInGroup)
			end

			if cachedRoles[player.UserId] then
				usernameLabel.Text = string.format('<font color="%s">[Member]</font>\n%s', ROLE_COLORS["Member"], player.Name)
			else
				usernameLabel.Text = player.Name
			end
		end)
	end

	updateAllStates(player)
end

-- ==========================================
-- INIT
-- ==========================================
local function onPlayerAdded(player)
	--player:SetAttribute("IsAFK", false) -- force to turn off afk in this udpate

	if player.Character then task.spawn(setupOverhead, player, player.Character) end
	player.CharacterAdded:Connect(function(char) setupOverhead(player, char) end)

	PlayerData.ObserveAll(player, function(attribute)
		if trackedAttributes[attribute] then updateAllStates(player) end
	end)
end

function OverheadController.Init()
	for _, player in ipairs(Players:GetPlayers()) do onPlayerAdded(player) end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player) cachedRoles[player.UserId] = nil end)
end

return OverheadController
