-- Owns player overhead content and resolves combat and invisibility visibility together.
local OverheadController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LeagueConfig = require(ReplicatedStorage.SharedModules.LeagueConfig)
local LeagueUtil = require(ReplicatedStorage.Utils.LeagueUtil)
local RobuxShopConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("RobuxShopConfig"))
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

-- Comment out an attribute to disable it
local TRACKING_ATTRIBUTES = {
	"Invisible",
	"Lives",
	"Trophies",
	"GamesPlayed",
	"IsOnArena",
	"IsInTrainingArena",
	"IsAFK",
	"Hardware",
	PassesConfig.VIP.Attribute,
}

local heartTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local textTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local heightTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local cachedRoles = {}

type GuiState = {
	Defaults: { [Instance]: { [string]: number } },
	Tweens: { [Instance]: Tween },
	TrophiesThread: thread?,
	Combat: boolean?,
}
local GuiStates: { [BillboardGui]: GuiState } = {}
local INVISIBLE_TWEEN = TweenInfo.new(0.375, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function PrepareGui(gui: BillboardGui)
	-- Set ownership before parenting, so InvisibleEffect never captures these descendants.
	gui:SetAttribute("OverheadVisibilityManaged", true)
	local state: GuiState = { Defaults = {}, Tweens = {}, TrophiesThread = nil, Combat = nil }
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
		if state.TrophiesThread then task.cancel(state.TrophiesThread); state.TrophiesThread = nil end
		for _, tween in state.Tweens do tween:Cancel(); tween:Destroy() end
		table.clear(state.Tweens)
		table.clear(state.Defaults)
	end)
end

local function UpdateTransparency(player: Player, gui: BillboardGui)
	local state = GuiStates[gui]
	if not state then return end
	local invisible = player:GetAttribute("Invisible") == true
	local combat = player:GetAttribute("IsOnArena") or player:GetAttribute("IsInTrainingArea")
	local trophies = gui:FindFirstChild("Trophies")
	local lives = player:GetAttribute("Lives") or MAX_LIVES
	for item, defaults in state.Defaults do
		if not item:IsDescendantOf(gui) then continue end
		local goals = table.clone(defaults)
		local heartIndex = tonumber(string.match(item.Name, "^Heart_(%d+)$"))
		if heartIndex and goals.ImageTransparency ~= nil then
			goals.ImageTransparency = if heartIndex <= lives then 0 else 0.65
		end
		if trophies and item:IsDescendantOf(trophies) then
			-- Preserve the existing lobby appearance even if the template starts faded out.
			if goals.TextTransparency ~= nil then goals.TextTransparency = 0 end
			if goals.TextStrokeTransparency ~= nil then goals.TextStrokeTransparency = 0 end
			if item:IsA("UIStroke") then goals.Transparency = 0 end
		end
		-- Invisibility takes precedence, while combat affects only the trophies contents.
		if invisible or (combat and trophies and item:IsDescendantOf(trophies)) then
			for property in goals do goals[property] = 1 end
		end
		local old = state.Tweens[item]
		if old then old:Cancel(); old:Destroy() end
		local tween = TweenService:Create(item, if invisible then INVISIBLE_TWEEN else textTweenInfo, goals)
		state.Tweens[item] = tween
		tween:Play()
	end
end

-- ==========================================
-- UI UPDATE LOGIC
-- ==========================================
local function updateHearts(player, gui)
	local currentLives = player:GetAttribute("Lives") or MAX_LIVES
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
	local isCombat = player:GetAttribute("IsOnArena") == true or player:GetAttribute("IsInTrainingArea") == true
	
	local trophiesFrame = gui:FindFirstChild("Trophies") :: Frame
	if not trophiesFrame then
		return
	end
	local state = GuiStates[gui]
	if not state or state.Combat == isCombat then return end
	state.Combat = isCombat
	if state.TrophiesThread then task.cancel(state.TrophiesThread); state.TrophiesThread = nil end
	if not isCombat then
		trophiesFrame.Visible = true -- Reveal the frame before fading its contents back in.
		return
	end
	state.TrophiesThread = task.delay(textTweenInfo.Time, function()
		state.TrophiesThread = nil
		if GuiStates[gui] == state and gui.Parent and trophiesFrame.Parent and state.Combat then
			trophiesFrame.Visible = false
		end
	end)
end

local function updateHeights(player, usernameGui)
	local inArena = player:GetAttribute("IsOnArena")
	local isCombat = inArena or player:GetAttribute("IsInTrainingArea")

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
		heartsGui.Enabled = (player:GetAttribute("IsOnArena") == true)
	end

	local afkText = if usernameGui then usernameGui:FindFirstChild("AFKText") :: TextLabel else nil
	if usernameGui then
		local trophiesText = usernameGui:FindFirstChild("TrophiesText", true)
		local leagueImg = trophiesText.Parent.ImageLabel :: ImageLabel
		local trophies = tostring(player:GetAttribute("Trophies") or 0)
		local gamesPlayed = tonumber(player:GetAttribute("GamesPlayed"))

		if not gamesPlayed or not math.isfinite(gamesPlayed) or gamesPlayed < LeagueConfig.GamesPlayedRequirement then
			trophies = " UNRANKED"
			leagueImg.ImageColor3 = Color3.new(0,0,0)
		else
			local leagueData = LeagueUtil.GetLeague(trophies)
			leagueImg.Image = leagueData.Icon
			leagueImg.ImageColor3 = Color3.new(1,1,1)
		end

		if trophiesText then trophiesText.Text = trophies end

		updateCombatState(player, usernameGui)

		local hwIcon = usernameGui:FindFirstChild("HardwareIcon", true)
		if hwIcon then hwIcon.Image = HARDWARE_ICONS[player:GetAttribute("Hardware") or "PC"] or HARDWARE_ICONS["PC"] end
	end

	local vipText = if usernameGui then usernameGui:FindFirstChild("VIP") :: TextLabel else nil

	if vipText then vipText.Visible = player:GetAttribute(PassesConfig.VIP.Attribute) == true end
	if afkText then afkText.Visible = (player:GetAttribute("IsAFK") == true) end
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

	player.AttributeChanged:Connect(function(attribute)
		if table.find(TRACKING_ATTRIBUTES, attribute) then
			updateAllStates(player)
		end
	end)
end

function OverheadController.Init()
	for _, player in ipairs(Players:GetPlayers()) do onPlayerAdded(player) end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player) cachedRoles[player.UserId] = nil end)
end

return OverheadController
