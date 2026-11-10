local NpcController = {}
local initialized = false
local observed = {}
local npcStateUpdates = {}
local playerAFKConnections = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Events = ReplicatedStorage:WaitForChild("Events")
local NpcAttackEvent = Events:WaitForChild("NpcAttackEvent")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local LeagueConfig = require(ReplicatedStorage.SharedModules.LeagueConfig)
local LeagueUtil = require(ReplicatedStorage.Utils.LeagueUtil)
local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))

local Assets = ReplicatedStorage:WaitForChild("Assets")
local Overheads = Assets:WaitForChild("Overheads")
local OverheadHeartsGuiTemplate = Overheads:WaitForChild("OverheadHeartsGui")
local OverheadUsernameGuiTemplate = Overheads:WaitForChild("OverheadUsernameGui")

local SFX = SoundService:WaitForChild("SFX")
local activeAttacks = {}
local MAX_LIVES = 3
local heartTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function areAllPlayersAFK(): boolean
	local players = Players:GetPlayers()
	if #players == 0 then return false end
	for _, player in players do
		if player:GetAttribute("IsAFK") ~= true then
			return false
		end
	end
	return true
end

local function refreshNpcStates()
	for _, update in npcStateUpdates do
		update()
	end
end

local function watchPlayerAFK(player: Player)
	if playerAFKConnections[player] then return end
	playerAFKConnections[player] = player:GetAttributeChangedSignal("IsAFK"):Connect(refreshNpcStates)
end

-- ==========================================
-- OVERHEAD HELPERS (NPC)
-- ==========================================
local function updateHeartsVisual(npc, gui)
	if not gui then return end
	local currentLives = npc:GetAttribute("Lives") or MAX_LIVES

	for i = 1, MAX_LIVES do
		local heart = gui:FindFirstChild("Heart_" .. i)
		if heart then
			local isAlive = (i <= currentLives)
			local targetColor = isAlive and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(30, 30, 30)
			local targetTransparency = isAlive and 0 or 0.65

			TweenService:Create(heart, heartTweenInfo, {
				ImageColor3 = targetColor,
				ImageTransparency = targetTransparency
			}):Play()
		end
	end
end

local function setupOverheads(npc: Model, connections)
	if npc:HasTag("ArenaNPC") and string.find(npc.Name, "Noob_NPC_") then
		npc:GetPropertyChangedSignal("Name"):Once(function()
			setupOverheads(npc, connections)
		end)
		return
	end
	local head = npc:WaitForChild("Head", 5)
	if not head or observed[npc] ~= connections or not npc:IsDescendantOf(workspace) then return end

	if head:FindFirstChild("OverheadHeartsGui") then head.OverheadHeartsGui:Destroy() end
	if head:FindFirstChild("OverheadUsernameGui") then head.OverheadUsernameGui:Destroy() end

	-- 1. SETUP CUORI
	local heartsGui = OverheadHeartsGuiTemplate:Clone()
	heartsGui.Name = "OverheadHeartsGui"
	heartsGui.Adornee = head
	heartsGui.Parent = head

	-- Clonazione dei cuori come fa l'OverheadController del player
	local temp = heartsGui:WaitForChild("HeartTemp", 2)
	if observed[npc] ~= connections or not head.Parent then heartsGui:Destroy(); return end
	if temp then
		temp.Visible = false
		for i = 1, MAX_LIVES do
			local heart = temp:Clone()
			heart.Name = "Heart_" .. i
			heart.Visible = true
			heart.Parent = heartsGui
		end
	end

	updateHeartsVisual(npc, heartsGui)
	heartsGui.Enabled = (npc:GetAttribute("IsOnArena") == true)

	local usernameGui = OverheadUsernameGuiTemplate:Clone()
	usernameGui.Name = "OverheadUsernameGui"
	usernameGui.Adornee = head
	usernameGui.Parent = head

	-- Hide the complete wins row in the new GUI.
	local winsFrame = usernameGui:FindFirstChild("Wins")
	if winsFrame then
		winsFrame.Visible = false
	end

	local afkText = usernameGui:FindFirstChild("AFKText")

	local icon = usernameGui:FindFirstChild("HardwareIcon", true)
	if icon then
		icon.Image = "rbxassetid://103495637950753"
	end

	local usernameLabel = usernameGui:FindFirstChild("PlayerUsernameText", true)
	if usernameLabel then
		usernameLabel.RichText = false
		usernameLabel.Text = npc.Name
	end

	local originalStudsY = usernameGui.StudsOffset.Y
	local trophiesFrame = usernameGui:FindFirstChild("Trophies")

	local function updateNpcStates()
		if observed[npc] ~= connections or not head.Parent then
			return
		end

		local inArena = npc:GetAttribute("IsOnArena") == true
		local isCombat = inArena
			or npc:GetAttribute("IsInTrainingArea") == true
		local isAFK = CollectionService:HasTag(npc, "LobbyNPC") and not inArena and npc:GetAttribute("IsAFK") == true -- set by LobbyNPCService
		if CollectionService:HasTag(npc, "LobbyNPC") and npc:GetAttribute("IsAFK") ~= isAFK then
			npc:SetAttribute("IsAFK", isAFK)
		end
		if afkText then
			afkText.Visible = isAFK
		end

		updateHeartsVisual(npc, heartsGui)
		heartsGui.Enabled = inArena
		trophiesFrame.Visible = not inArena

		-- Same height calculation as OverheadController.
		local reduction = (inArena and 0 or 1.2)
			+ (isCombat and 0.6 or 0)

		usernameGui.StudsOffset = Vector3.new(
			0,
			originalStudsY - reduction,
			0
		)
	end

	for _, attribute in {
		"Lives",
		"IsOnArena",
		"IsInTrainingArea",
		"IsAFK",
		} do
		table.insert(
			connections,
			npc:GetAttributeChangedSignal(attribute):Connect(updateNpcStates)
		)
	end
	npcStateUpdates[npc] = updateNpcStates

	
	local trophiesText = usernameGui:FindFirstChild("TrophiesText", true)
	local leagueImg = trophiesText.Parent.ImageLabel :: ImageLabel
	local vipText = if usernameGui then usernameGui:FindFirstChild("VIP") :: TextLabel else nil
	local function updateNpcProfile()
		local trophies = npc:GetAttribute("Trophies") or 0
		local gamesPlayed = npc:GetAttribute("GamesPlayed") or 0

		if gamesPlayed < LeagueConfig.GamesPlayedRequirement then
			if trophiesText then trophiesText.Text = " UNRANKED" end
			leagueImg.ImageColor3 = Color3.new(0, 0, 0)
		else
			local leagueData = LeagueUtil.GetLeague(trophies)
			if trophiesText then trophiesText.Text = tostring(trophies) end
			leagueImg.Image = leagueData.Icon
			leagueImg.ImageColor3 = Color3.new(1, 1, 1)
		end

		if vipText then
			vipText.Visible = npc:GetAttribute("HasVIP") == true
		end
	end
	for _, attribute in { "Trophies", "GamesPlayed", "HasVIP" } do
		table.insert(connections, npc:GetAttributeChangedSignal(attribute):Connect(updateNpcProfile))
	end
	updateNpcProfile()

	updateNpcStates()

	--local connection = npc:GetAttributeChangedSignal("Lives"):Connect(function()
	--	updateHeartsVisual(npc, heartsGui)
	--end)
	--if observed[npc] then table.insert(observed[npc], connection) else connection:Disconnect() end
end

-- ==========================================
-- UTILS (Combat)
-- ==========================================
local function cancelAttack(npc)
	local data = activeAttacks[npc]
	if not data then return end
	activeAttacks[npc] = nil
	if data.connection then data.connection:Disconnect() end
	if data.ended then data.ended:Disconnect() end
	if data.track then data.track:Stop(0); data.track:Destroy() end
	if data.animation then data.animation:Destroy() end
end

local function handleNpcAttack(npc, weaponId, action)
	if not npc or not npc:IsDescendantOf(workspace) then return end
	if action == "Cancel" or npc:GetAttribute("IsRagdolled") or npc:GetAttribute("IsFrozen") then cancelAttack(npc); return end
	local hum = npc:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	local weapon = WeaponConfig.BaseWeapons[weaponId]
	if not animator or not weapon then return end -- Wait for the server Animator; never create a local duplicate.
	if action == "Charge" then
		if activeAttacks[npc] and not activeAttacks[npc].released then return end
		cancelAttack(npc)
		local animation = Instance.new("Animation")
		local attack = if hum.FloorMaterial == Enum.Material.Air then weapon.JumpAttack else weapon.Attack
		animation.Name, animation.AnimationId = "WeaponAttack", attack.AnimationId
		local track = animator:LoadAnimation(animation)
		local data = {track = track, animation = animation, generation = npc:GetAttribute("RagdollGeneration"), released = false,
			connection = nil :: RBXScriptConnection?, ended = nil :: RBXScriptConnection?}
		activeAttacks[npc] = data
		track.Priority, track.Looped = Enum.AnimationPriority.Action, false
		track:Play()
		local loadedAt = os.clock()
		data.connection = RunService.Heartbeat:Connect(function()
			if activeAttacks[npc] ~= data or not npc:IsDescendantOf(workspace) or npc:GetAttribute("IsRagdolled")
				or npc:GetAttribute("IsFrozen") or npc:GetAttribute("RagdollGeneration") ~= data.generation then cancelAttack(npc); return end
			if track.Length <= 0 then if os.clock() - loadedAt > 5 then cancelAttack(npc) end; return end
			local holdAt = track.Length * (attack.TrackChargeThreshold or 0.4)
			if track.TimePosition >= holdAt then
				track:AdjustSpeed(0); track.TimePosition = holdAt
				data.connection:Disconnect(); data.connection = nil
			else track:AdjustSpeed(math.clamp(1 - track.TimePosition / holdAt, 0.1, 1)) end
		end)
	elseif action == "Release" then
		local data = activeAttacks[npc]
		if data then
			if data.connection then data.connection:Disconnect(); data.connection = nil end
			data.released = true
			data.track:AdjustSpeed(1)
			data.ended = data.track.Ended:Connect(function() if activeAttacks[npc] == data then cancelAttack(npc) end end)
			task.delay(5, function() if activeAttacks[npc] == data then cancelAttack(npc) end end)
		end
		local sound, root = SFX:FindFirstChild("WeaponSwing"), npc:FindFirstChild("HumanoidRootPart")
		if sound and root then local clone = sound:Clone(); clone.Parent = root; clone:Play(); game:GetService("Debris"):AddItem(clone, 2) end
	end
end

local function releaseNpc(npc)
	cancelAttack(npc)
	npcStateUpdates[npc] = nil
	local connections = observed[npc]
	observed[npc] = nil
	if connections then for _, connection in connections do connection:Disconnect() end end
end

local function observeNpc(npc)
	if observed[npc] then
		local update = npcStateUpdates[npc]
		if update then update() end
		return
	end
	local connections = {}
	observed[npc] = connections
	for _, attribute in {"IsRagdolled", "IsFrozen", "RagdollGeneration"} do
		table.insert(connections, npc:GetAttributeChangedSignal(attribute):Connect(function()
			if attribute == "RagdollGeneration" or npc:GetAttribute("IsRagdolled") or npc:GetAttribute("IsFrozen") then cancelAttack(npc) end
		end))
	end
	local function resumeCharge()
		if observed[npc] == connections and npc:GetAttribute("IsCharging") and not activeAttacks[npc] then
			handleNpcAttack(npc, npc:GetAttribute("EquippedBaseWeapon") or "Slap", "Charge")
		end
	end
	table.insert(connections, npc:GetAttributeChangedSignal("IsCharging"):Connect(resumeCharge))
	table.insert(connections, npc.DescendantAdded:Connect(function(item)
		if item:IsA("Animator") then resumeCharge() end
	end))
	table.insert(connections, npc.Destroying:Connect(function() releaseNpc(npc) end))
	-- Shadow Clones are NPC-driven (attack animations, cancel on ragdoll) but have no hearts / name tag.
	if not CollectionService:HasTag(npc, "ShadowClone") then
		task.spawn(setupOverheads, npc, connections)
	end
	resumeCharge()
end

-- ==========================================
-- INIT
-- ==========================================
function NpcController.Init()
	if initialized then return end
	initialized = true
	NpcAttackEvent.OnClientEvent:Connect(handleNpcAttack)
	for _, tag in {"ArenaNPC", "TraningNPC", "LobbyNPC", "ShadowClone"} do
		CollectionService:GetInstanceAddedSignal(tag):Connect(observeNpc)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(npc)
			if CollectionService:HasTag(npc, "ArenaNPC")
				or CollectionService:HasTag(npc, "TraningNPC")
				or CollectionService:HasTag(npc, "LobbyNPC")
				or CollectionService:HasTag(npc, "ShadowClone") then
				local update = npcStateUpdates[npc]
				if update then update() end
				return
			end
			releaseNpc(npc)
		end)
		for _, npc in CollectionService:GetTagged(tag) do observeNpc(npc) end
	end
	for _, player in Players:GetPlayers() do
		watchPlayerAFK(player)
	end
	Players.PlayerAdded:Connect(function(player)
		watchPlayerAFK(player)
		refreshNpcStates()
	end)
	Players.PlayerRemoving:Connect(function(player)
		local connection = playerAFKConnections[player]
		if connection then
			connection:Disconnect()
			playerAFKConnections[player] = nil
		end
		refreshNpcStates()
	end)
end

return NpcController
