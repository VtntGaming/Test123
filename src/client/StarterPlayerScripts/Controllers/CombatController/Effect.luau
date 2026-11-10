--!strict
local Effect = {}

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local WeaponConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("WeaponConfig"))

local CLEANUP_MARGIN = 0.5
local initialized = false
local effectsFolder: Folder? = nil

local function getEffectsFolder(): Folder
	local existing = effectsFolder
	if existing and existing.Parent == Workspace then return existing end
	local folder = Instance.new("Folder")
	folder.Name = "CombatLocalEffects"
	folder.Parent = Workspace
	effectsFolder = folder
	return folder
end

local function finiteVector(value: Vector3): boolean
	return value.X == value.X and value.Y == value.Y and value.Z == value.Z
		and math.abs(value.X) < math.huge and math.abs(value.Y) < math.huge
		and math.abs(value.Z) < math.huge
end

local function preparePart(part: BasePart)
	part.Anchored = true
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function emitHit(template: BasePart, position: Vector3, direction: Vector3)
	if not finiteVector(position) or not finiteVector(direction) or direction.Magnitude < 0.001 then return end
	local effect = template:Clone()
	preparePart(effect)
	local emitters: {ParticleEmitter} = {}
	local lifetime = 0
	for _, descendant in effect:GetDescendants() do
		if descendant:IsA("BasePart") then
			preparePart(descendant)
		elseif descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
			table.insert(emitters, descendant)
			lifetime = math.max(lifetime, descendant.Lifetime.Max / math.max(descendant.TimeScale, 0.01))
		end
	end
	effect.CFrame = CFrame.lookAt(position, position + direction.Unit)
	effect.Parent = getEffectsFolder()
	for _, emitter in emitters do
		local count = emitter:GetAttribute("EmitCount")
		local amount = if type(count) == "number" and count == count and math.abs(count) < math.huge
			then math.max(1, math.floor(count)) else 1
		emitter:Emit(amount*1.5)
	end
	Debris:AddItem(effect, lifetime + CLEANUP_MARGIN)
end

function Effect.Init()
	if initialized then return end
	initialized = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEffects")
	local vfx = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("VFX")
	local template = vfx:WaitForChild("HitEffect")
	assert(remote:IsA("RemoteEvent"), "CombatEffects must be a RemoteEvent")
	assert(template:IsA("BasePart"), "HitEffect must be a BasePart")
	getEffectsFolder()
	remote.OnClientEvent:Connect(function(weaponId: any, position: any, direction: any, weaponName: any)
		if typeof(position) ~= "Vector3" or typeof(direction) ~= "Vector3" then return end
		local hitTemplate = template
		if WeaponConfig.HitEffectMode == "WeaponBasedHitEffect" then
			local name = if type(weaponName) == "string" and weaponName ~= "" then weaponName else weaponId
			local templates = vfx:FindFirstChild("HitEffects")
			local weaponTemplate = if templates and type(name) == "string" and name ~= ""
				then templates:FindFirstChild(name) else nil
			if weaponTemplate and weaponTemplate:IsA("BasePart") then
				hitTemplate = weaponTemplate
			end
		end
		emitHit(hitTemplate, position, direction)
	end)
end

return Effect

