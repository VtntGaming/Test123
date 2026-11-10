-- Owns npc service behavior and accesses player state through the shared data API.
local NpcService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Events = ReplicatedStorage:WaitForChild("Events")
local NpcAttackEvent = Events:WaitForChild("NpcAttackEvent")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local PlayerData = require(ReplicatedStorage.PlayerData)
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))
local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))

local CombatService = require(script.Parent:WaitForChild("CombatService"))
local RagdollService = require(script.Parent:WaitForChild("RagdollService"))
local SimulationState = require(ReplicatedStorage.Simulation.State)

local Assets = ReplicatedStorage:WaitForChild("Assets")
local CustomAnimations = Assets:WaitForChild("Animations"):WaitForChild("Character")

-- ==========================================
-- STATE CACHE
-- ==========================================
local initialized = false
local activeNPCs = {} 

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

local function initializeNpc(npc)
	if activeNPCs[npc] then return end
	local npcType = if CollectionService:HasTag(npc, "ArenaNPC") then "Arena" else "Lobby"
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

		-- The shared Animator owns locomotion and action tracks in server authority mode.
		animateScript.Enabled = false
	end

	local hand = npc:WaitForChild("RightHand", 5) 
	local weaponTemplate = Assets:WaitForChild("Weapons"):FindFirstChild("Slap")

	if weaponTemplate and hand then
		local weaponModel = weaponTemplate:Clone()
		weaponModel.Name = "EquippedWeapon"
		weaponModel:SetAttribute("WeaponId", "Slap")
		weaponModel:SetAttribute("WeaponName", "Slap")
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
			npc:SetAttribute("EquippedBaseWeapon", "Slap")

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

local function cleanupNpc(npc)
	local data = activeNPCs[npc]
	if not data then return end
	cancelAttack(npc, data)
	for _, connection in data.connections do connection:Disconnect() end
	activeNPCs[npc] = nil
end

local function positionOf(actor)
	return RagdollService.GetAuthoritativePosition(actor)
end

local function PublishDirection(npc: Model, root: BasePart, direction: Vector3)
	SimulationState.Queue(npc, function()
		local record = SimulationState.Records[npc]
		if record and record.Root == root then
			Attributes.Set(root, "SANpcDirection", direction)
		end
	end)
end

local function updateNPCsAI()
	local now = time()
	for npc, data in activeNPCs do
		local root, hum = npc:FindFirstChild("HumanoidRootPart"), npc:FindFirstChildOfClass("Humanoid")
		if not npc:IsDescendantOf(workspace) then continue end
		if not root or not root:IsA("BasePart") then
			cancelAttack(npc, data)
			continue
		end
		if not hum or hum.Health <= 0 or (npc:GetAttribute("Lives") or 0) <= 0 then
			cancelAttack(npc, data)
			PublishDirection(npc, root, Vector3.zero)
			continue
		end
		if RagdollService.IsRagdolled(npc) or npc:GetAttribute("IsFrozen") or root.Anchored then
			cancelAttack(npc, data)
			PublishDirection(npc, root, Vector3.zero)
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
			local inZone = if data.type == "Arena"
				then PlayerData.Get(player, "IsOnArena")
				else PlayerData.Get(player, "IsInTrainingArea")
			if inZone and not PlayerData.Get(player, "IsInvulnerable") and player.Character then
				consider(player.Character)
			end
		end
		if data.type == "Arena" then
			for other, otherData in activeNPCs do
				if other ~= npc and otherData.type == "Arena" and (other:GetAttribute("Lives") or 0) > 0 then consider(other) end
			end
		end
		local function faceTarget()
			if not targetPosition then return end
			local aim = Vector3.new(targetPosition.X, root.Position.Y, targetPosition.Z)
			if (aim - root.Position).Magnitude > 0.001 then
				SimulationState.Queue(npc, function()
					root.CFrame = CFrame.lookAt(root.Position, aim)
				end)
			end
		end
		local direction = Vector3.zero
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
			if closestDistance > 4.5 then
				direction = (targetPosition - root.Position).Unit
			else
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
			if spawnPosition and (origin - spawnPosition).Magnitude > 2 then
				direction = (spawnPosition - root.Position).Unit
			end
		end
		PublishDirection(npc, root, direction)
	end
end

-- ==========================================
-- INIT
-- ==========================================
function NpcService.Init()
	if initialized then return end
	initialized = true
	CollectionService:GetInstanceAddedSignal("ArenaNPC"):Connect(initializeNpc)
	CollectionService:GetInstanceAddedSignal("LobbyNPC"):Connect(initializeNpc)

	CollectionService:GetInstanceRemovedSignal("ArenaNPC"):Connect(cleanupNpc)
	CollectionService:GetInstanceRemovedSignal("LobbyNPC"):Connect(cleanupNpc)

	for _, npc in ipairs(CollectionService:GetTagged("ArenaNPC")) do
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
