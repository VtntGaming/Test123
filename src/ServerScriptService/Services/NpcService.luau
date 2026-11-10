local NpcService = {}
local initialized = false

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Events = ReplicatedStorage:WaitForChild("Events")
local NpcAttackEvent = Events:WaitForChild("NpcAttackEvent")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))
local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))

local CombatService = require(script.Parent:WaitForChild("CombatService"))
local RagdollService = require(script.Parent:WaitForChild("RagdollService"))

local Assets = ReplicatedStorage:WaitForChild("Assets")
local CustomAnimations = Assets:WaitForChild("Animations"):WaitForChild("Character")

-- ==========================================
-- STATE CACHE
-- ==========================================
local activeNPCs = {} 
type ArenaAppearance = {
	Description: HumanoidDescription,
	UserId: number,
	Username: string,
	Trophies: number,
	GamesPlayed: number,
	HasVIP: boolean,
}

local usedArenaUserIds: { [number]: boolean } = {}
local loadingArenaUserIds: { [number]: boolean } = {}
local ARENA_DESCRIPTION_ATTEMPTS = 100

local function markExistingArenaAppearanceIds()
	for _, tag in {"ArenaNPC", "TraningNPC", "LobbyNPC"} do
		for _, npc in CollectionService:GetTagged(tag) do
			local userId = npc:GetAttribute("ArenaAppearanceUserId")
			if type(userId) == "number" then
				usedArenaUserIds[userId] = true
			end
		end
	end
end

local function getRandomArenaAppearance(): ArenaAppearance?
	markExistingArenaAppearanceIds()

	for _ = 1, ARENA_DESCRIPTION_ATTEMPTS do
		local userId = 1 + math.floor((math.random() ^ 0.5) * 11_800_000_000)
		if usedArenaUserIds[userId] or loadingArenaUserIds[userId] then
			continue
		end
		loadingArenaUserIds[userId] = true

		local success, description = pcall(function()
			return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
		end)
		if success and description then
			local nameSuccess, username = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if nameSuccess and username then
				local appearance: ArenaAppearance = {
					Description = description,
					UserId = userId,
					Username = username,
					Trophies = math.random(25, 2000),
					GamesPlayed = math.random(0, 100),
					HasVIP = math.random(0, 10) == 0,
				}
				loadingArenaUserIds[userId] = nil
				markExistingArenaAppearanceIds()
				if usedArenaUserIds[userId] then
					continue
				end
				usedArenaUserIds[userId] = true
				return appearance
			end
		end
		loadingArenaUserIds[userId] = nil
	end

	return nil
end

function NpcService.GetRandomArenaAppearance(): ArenaAppearance?
	return getRandomArenaAppearance()
end

local function assignNpcProfile(npc, appearance: ArenaAppearance?)
	if appearance then
		npc:SetAttribute("ArenaAppearanceUserId", appearance.UserId)
	end
	if npc:GetAttribute("Trophies") == nil then
		npc:SetAttribute("Trophies", if appearance then appearance.Trophies else math.random(100, 10000))
	end
	if npc:GetAttribute("GamesPlayed") == nil then
		npc:SetAttribute("GamesPlayed", if appearance then appearance.GamesPlayed else math.random(0, 100))
	end
	if npc:GetAttribute("HasVIP") == nil then
		local botVIP = npc:GetAttribute("BotVIP")
		npc:SetAttribute(
			"HasVIP",
			if type(botVIP) == "boolean" then botVIP
			elseif appearance then appearance.HasVIP
			else math.random(0, 10) == 0
		)
	end
end

-- ==========================================
-- SETUP VISUALE & FISICO
-- ==========================================
local function replaceAnimationId(animateScript, animName, customAnimId)
	local animStringValue = animateScript:FindFirstChild(animName)
	if animStringValue then
		local anim = animStringValue:FindFirstChildOfClass("Animation")
		if anim then anim.AnimationId = customAnimId end
	end
end

local cleanupNpc

local function initializeNpc(npc)
	local npcType = if CollectionService:HasTag(npc, "ArenaNPC") then "Arena"
		elseif CollectionService:HasTag(npc, "LobbyNPC") then "LobbyNPC"
		else "Lobby"
	local currentData = activeNPCs[npc]
	if currentData then
		if currentData.type == npcType then return end
		cleanupNpc(npc, currentData.type)
	end
	local data = {model = npc, type = npcType, attackId = nil, connections = {}}
	activeNPCs[npc] = data
	for _, attribute in {"IsRagdolled", "IsFrozen", "RagdollGeneration"} do
		table.insert(data.connections, npc:GetAttributeChangedSignal(attribute):Connect(function()
			if attribute == "RagdollGeneration" or npc:GetAttribute("IsRagdolled") or npc:GetAttribute("IsFrozen") then
				CombatService.CancelActor(npc)
				data.attackId = nil
				npc:SetAttribute("IsCharging", false)
				NpcAttackEvent:FireAllClients(npc, "Slap", "Cancel")
			end
		end))
	end
	if not npc.Parent then npc.AncestryChanged:Wait() end
	if activeNPCs[npc] ~= data or not npc.Parent then return end

	local hum = npc:WaitForChild("Humanoid", 5)
	if hum then
		hum.MaxHealth = math.huge
		hum.Health = math.huge
		hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		hum.UseJumpPower = false
		hum.WalkSpeed = if npc:GetAttribute("IsFrozen") then 0 else GameConfig.Movement.WalkSpeed
		hum.JumpHeight = if npc:GetAttribute("IsFrozen") then 0 else GameConfig.Movement.JumpHeight
	end

	local isBot = npc:GetAttribute("IsBot") == true
	task.spawn(function()
		if npcType == "LobbyNPC" then return end
		local appearance = getRandomArenaAppearance()
		if activeNPCs[npc] ~= data or not npc:IsDescendantOf(workspace) then
			return
		end
		if not appearance then
			assignNpcProfile(npc, nil)
			warn("NpcService: unable to load an available user profile for an NPC")
			return
		end

		assignNpcProfile(npc, appearance)

		if not hum or npcType ~= "Arena" or isBot or hum.RigType ~= Enum.HumanoidRigType.R15 or hum.Parent ~= npc then
			return
		end

		local success, message = pcall(function()
			hum:ApplyDescription(appearance.Description:Clone())
		end)
		if not success then
			warn(`NpcService: failed to apply an arena NPC appearance: {message}`)
			return
		end
		npc.Name = appearance.Username
	end)

	npc:SetAttribute("LastAttackTime", 0)
	npc:SetAttribute("IsCharging", false)
	npc:SetAttribute("ChargeDuration", 1.2)

	-- Gli NPC partono con 3 vite
	npc:SetAttribute("Lives", 3) 

	

	-- Flag per il controller Client per capire se mostrare i cuori
	npc:SetAttribute("IsOnArena", (npcType == "Arena"))

	local animateScript = npc:WaitForChild("Animate", 3)
	if animateScript then
		replaceAnimationId(animateScript, "idle", CustomAnimations.Idle.AnimationId)
		replaceAnimationId(animateScript, "run", CustomAnimations.Running.AnimationId)
		replaceAnimationId(animateScript, "walk", CustomAnimations.Running.AnimationId)
		replaceAnimationId(animateScript, "jump", CustomAnimations.Jumping.AnimationId)

		local enabled = animateScript.Enabled
		animateScript.Enabled = false
		task.defer(function()
			if animateScript.Parent and not npc:GetAttribute("IsRagdolled") then animateScript.Enabled = enabled end
		end)
	end

	local hand = npc:WaitForChild("RightHand", 5) 
	local weaponsFolder = Assets:WaitForChild("Weapons")
	local baseWeaponId = if isBot then (npc:GetAttribute("BotWeapon") or "Slap") else "Slap"
	local weaponName = if isBot then (npc:GetAttribute("BotWeaponSkin") or baseWeaponId) else "Slap"
	local weaponTemplate = weaponsFolder:FindFirstChild(weaponName) or weaponsFolder:FindFirstChild(baseWeaponId) or weaponsFolder:FindFirstChild("Slap")

	if weaponTemplate and hand and npcType ~= "LobbyNPC" then
		local weaponModel = weaponTemplate:Clone()
		weaponModel.Name = "EquippedWeapon"
		weaponModel:SetAttribute("WeaponId", baseWeaponId)
		weaponModel:SetAttribute("WeaponName", weaponName)
		npc:SetAttribute("WeaponRevision", (npc:GetAttribute("WeaponRevision") or 0) + 1)

		local mainPart = weaponModel:FindFirstChild("Main")
		if mainPart then
			for _, part in ipairs(weaponModel:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
					part.Massless = true 
					if part ~= mainPart then
						local w = Instance.new("WeldConstraint")
						w.Part0 = mainPart
						w.Part1 = part
						w.Parent = mainPart
						part.Anchored = false
					end
				end
			end

			mainPart.Anchored = false
			weaponModel.Parent = npc
			npc:SetAttribute("EquippedBaseWeapon", baseWeaponId)

			mainPart.CFrame = hand.CFrame
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hand
			weld.Part1 = mainPart
			weld.Parent = mainPart
		end
	end
end

local function cancelAttack(npc, data)
	if data.attackId or npc:GetAttribute("IsCharging") then
		CombatService.CancelActor(npc)
		data.attackId = nil
		npc:SetAttribute("IsCharging", false)
		NpcAttackEvent:FireAllClients(npc, "Slap", "Cancel")
	end
end

cleanupNpc = function(npc, expectedType)
	local data = activeNPCs[npc]
	if not data or (expectedType and data.type ~= expectedType) then return end
	cancelAttack(npc, data)
	for _, connection in data.connections do connection:Disconnect() end
	activeNPCs[npc] = nil
end

local function positionOf(actor)
	return RagdollService.GetAuthoritativePosition(actor)
end

local function updateNPCsAI()
	local now = os.clock()
	local trainingBots -- lobby bots currently practising in the Training Area (built once per tick, only if needed)
	for npc, data in activeNPCs do
		local root, hum = npc:FindFirstChild("HumanoidRootPart"), npc:FindFirstChildOfClass("Humanoid")
		if not npc:IsDescendantOf(workspace) then continue end
		if data.type == "LobbyNPC" then continue end
		if npc:GetAttribute("IsBot") then continue end -- BotService drives bots (wander, never chase)
		if not root or not hum or hum.Health <= 0 or (npc:GetAttribute("Lives") or 0) <= 0 then cancelAttack(npc, data); continue end
		if RagdollService.IsRagdolled(npc) or npc:GetAttribute("IsFrozen") or root.Anchored then
			cancelAttack(npc, data)
			hum:Move(Vector3.zero)
			continue
		end
		local origin = positionOf(npc) or root.Position
		local closestDistance, targetPosition = math.huge, nil
		local function consider(actor)
			local humTarget = actor:FindFirstChildOfClass("Humanoid")
			local position = positionOf(actor)
			if not position or not humTarget or humTarget.Health <= 0 then return end
			if data.type == "Lobby" then
				local spawnPosition = npc:GetAttribute("SpawnPosition")
				if spawnPosition and (position - spawnPosition).Magnitude > (npc:GetAttribute("TerritoryRadius") or 25) then return end
			end
			if position.Y < origin.Y - 5 then return end -- actor has fall down the edge
			local distance = (position - origin).Magnitude
			if distance < closestDistance then closestDistance, targetPosition = distance, position end
		end
		for _, player in Players:GetPlayers() do
			local inZone = if data.type == "Arena" then player:GetAttribute("IsOnArena") else player:GetAttribute("IsInTrainingArea")
			if inZone and not player:GetAttribute("IsInvulnerable") and player.Character then consider(player.Character) end
		end
		if data.type == "Lobby" then
			-- Training NPCs also chase bots that are training (LobbyNPCService sets IsInTrainingArea on them)
			if not trainingBots then
				trainingBots = {}
				for _, bot in CollectionService:GetTagged("LobbyNPC") do
					if bot:GetAttribute("IsInTrainingArea") then table.insert(trainingBots, bot) end
				end
			end
			for _, bot in trainingBots do consider(bot) end
		elseif data.type == "Arena" then
			for other, otherData in activeNPCs do
				if other ~= npc and otherData.type == "Arena" and (other:GetAttribute("Lives") or 0) > 0 then consider(other) end
			end
		end
		local function faceTarget()
			if not targetPosition then return end
			local aim = Vector3.new(targetPosition.X, root.Position.Y, targetPosition.Z)
			if (aim - root.Position).Magnitude > 0.001 then root.CFrame = CFrame.lookAt(root.Position, aim) end
		end
		if data.attackId then
			faceTarget()
			if now >= data.releaseAt then
				local attackId = data.attackId
				data.attackId = nil
				npc:SetAttribute("IsCharging", false)
				npc:SetAttribute("LastAttackTime", now)
				if CombatService.ReleaseNpcAttack(npc, attackId) then
					NpcAttackEvent:FireAllClients(npc, "Slap", "Release")
				else NpcAttackEvent:FireAllClients(npc, "Slap", "Cancel") end
			end
		elseif targetPosition then
			if closestDistance > 4.5 then hum:MoveTo(targetPosition)
			else
				hum:MoveTo(root.Position)
				faceTarget()
				if now - (npc:GetAttribute("LastAttackTime") or 0) >= WeaponConfig.BaseWeapons.Slap.Cooldown then
					local attackId = CombatService.BeginNpcAttack(npc)
					if attackId then
						local duration = math.random(5, 14) / 10
						data.attackId, data.releaseAt = attackId, now + duration
						npc:SetAttribute("IsCharging", true)
						npc:SetAttribute("ChargeStartTime", now)
						npc:SetAttribute("ChargeDuration", duration)
						NpcAttackEvent:FireAllClients(npc, "Slap", "Charge")
					end
				end
			end
		elseif data.type == "Lobby" then
			local spawnPosition = npc:GetAttribute("SpawnPosition")
			if spawnPosition and (origin - spawnPosition).Magnitude > 2 then hum:MoveTo(spawnPosition) end
		end
	end
end

-- ==========================================
-- INIT
-- ==========================================
function NpcService.Init()
	if initialized then return end
	initialized = true
	CollectionService:GetInstanceAddedSignal("ArenaNPC"):Connect(initializeNpc)
	CollectionService:GetInstanceAddedSignal("TraningNPC"):Connect(initializeNpc)
	CollectionService:GetInstanceAddedSignal("LobbyNPC"):Connect(initializeNpc)

	CollectionService:GetInstanceRemovedSignal("ArenaNPC"):Connect(function(npc)
		cleanupNpc(npc, "Arena")
	end)
	CollectionService:GetInstanceRemovedSignal("TraningNPC"):Connect(function(npc)
		cleanupNpc(npc, "Lobby")
	end)
	CollectionService:GetInstanceRemovedSignal("LobbyNPC"):Connect(function(npc)
		cleanupNpc(npc, "LobbyNPC")
	end)

	for _, npc in ipairs(CollectionService:GetTagged("ArenaNPC")) do
		task.spawn(initializeNpc, npc)
	end
	for _, npc in ipairs(CollectionService:GetTagged("TraningNPC")) do
		task.spawn(initializeNpc, npc)
	end
	for _, npc in ipairs(CollectionService:GetTagged("LobbyNPC")) do
		task.spawn(initializeNpc, npc)
	end

	task.spawn(function()
		while task.wait(0.1) do
			updateNPCsAI()
		end
	end)
end

return NpcService
