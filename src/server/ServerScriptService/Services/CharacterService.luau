-- Owns character service behavior and accesses player state through the shared data API.
local CharacterService = {}
local initialized = false
local players = {}
local characters = setmetatable({}, {__mode = "k"})

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local PlayerData = require(ReplicatedStorage.PlayerData)
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))

local CustomAnimations = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Animations"):WaitForChild("Character")

-- ==========================================
-- ANIMATION LOGIC
-- ==========================================
local function replaceAnimationId(animateScript, animName, customAnimId)
	local animStringValue = animateScript:FindFirstChild(animName)
	if animStringValue then
		local anim = animStringValue:FindFirstChildOfClass("Animation")
		if anim then
			anim.AnimationId = customAnimId
		end
	end
end

local function setupCharacter(character)
	if characters[character] then return end
	characters[character] = true
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid or not character.Parent then return end
	local player = Players:GetPlayerFromCharacter(character)

	humanoid.MaxHealth = math.huge
	humanoid.Health = math.huge
	--humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	-- ==========================================
	-- MOVEMENT
	-- ==========================================
	humanoid.UseJumpPower = false 
	humanoid.JumpHeight = if player and PlayerData.Get(player, "IsFrozen") then 0 else GameConfig.Movement.JumpHeight
	humanoid.WalkSpeed = if player and PlayerData.Get(player, "IsFrozen") then 0 else GameConfig.Movement.WalkSpeed

	-- ==========================================
	-- ANIMATIONS SETUP
	-- ==========================================
	local animateScript = character:WaitForChild("Animate", 5)
	if not animateScript or not character.Parent then return end
	replaceAnimationId(animateScript, "idle", CustomAnimations.Idle.AnimationId)
	replaceAnimationId(animateScript, "run", CustomAnimations.Running.AnimationId)
	replaceAnimationId(animateScript, "walk", CustomAnimations.Running.AnimationId)
	replaceAnimationId(animateScript, "jump", CustomAnimations.Jumping.AnimationId)

	if animateScript:IsA("BaseScript") then
		animateScript.Enabled = false -- Shared animation simulation owns gameplay tracks.
	end

	CollectionService:AddTag(character, "ArenaPlayer")
end

-- ==========================================
-- INIT
-- ==========================================
local function setupPlayer(player)
	if players[player] then return end
	players[player] = player.CharacterAdded:Connect(setupCharacter)
	if player.Character then task.spawn(setupCharacter, player.Character) end
end

function CharacterService.Init()
	if initialized then return end
	initialized = true
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(player)
		if players[player] then players[player]:Disconnect()
players[player] = nil end
	end)
	for _, player in Players:GetPlayers() do setupPlayer(player) end
end

return CharacterService
