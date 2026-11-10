--[[=^.^=]]--
local RunService = game:GetService("RunService")
local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")
local leftFoot = character:WaitForChild("LeftFoot")
local rightFoot = character:WaitForChild("RightFoot")

-- Crea un emettitore di particelle con impostazioni predefinite
-- English: Creates a particle emitter with default settings.
local function createParticleEmitter(parentPart, textureId)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = parentPart.Name .. "DustEffect"
	emitter.Parent = parentPart
	emitter.Enabled = false  -- Sempre disattivato
	-- English: Always disabled.
	emitter.LockedToPart = false
	emitter.LightEmission = 0.5
	emitter.Rate = 0  -- Nessuna emissione automatica
	-- English: No automatic emission.
	emitter.Lifetime = NumberRange.new(0.2, 0.4)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0.8)
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.6),
		NumberSequenceKeypoint.new(1, 1)
	})
	emitter.Texture = textureId
	return emitter
end

-- Inizializzazione degli effetti
-- English: Initialize the effects.
-- Effetto base (sempre attivo quando si cammina)
-- English: Base effect (always active while walking).
local baseLeftEmitter = createParticleEmitter(leftFoot, "rbxassetid://290833005") -- Texture di base
-- English: Base texture.
local baseRightEmitter = createParticleEmitter(rightFoot, "rbxassetid://290833005")

-- Effetto sabbia (attivo solo sulla sabbia)
-- English: Sand effect (only active on sand).
local SnowEffectLeft = script.FootstepEffects.Snow:Clone()
local SnowEffectRight = script.FootstepEffects.Snow:Clone()
SnowEffectLeft.Parent = leftFoot
SnowEffectRight.Parent = rightFoot

local isCharacterWalking = false
local stepInterval = 0.3
local timeSinceLastStep = 0
local isLeftFootTurn = true
local currentWalkSpeed = humanoid.WalkSpeed

-- Gestisce lo stato di movimento
-- English: Handles the movement state.
humanoid.Running:Connect(function(speed)
	isCharacterWalking = character:GetAttribute("IsRagdolled") ~= true and character:GetAttribute("IsFrozen") ~= true and speed > currentWalkSpeed / 2
end)

humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
	currentWalkSpeed = humanoid.WalkSpeed
end)

-- Logica principale degli effetti dei passi
-- English: Main footstep effect logic.
local heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
	if character:GetAttribute("IsRagdolled") or character:GetAttribute("IsFrozen") then timeSinceLastStep = 0; return end
	if not isCharacterWalking then return end

	local terrainMaterial = humanoid.FloorMaterial.Name
	local characterState = humanoid:GetState()

	-- Non mostrare effetti se in aria o arrampicandosi
	-- English: Do not show effects while airborne or climbing.
	if terrainMaterial == "Air" or characterState == Enum.HumanoidStateType.Climbing then
		return
	end

	timeSinceLastStep = timeSinceLastStep + deltaTime
	local adjustedStepInterval = stepInterval / (currentWalkSpeed / 16)

	if timeSinceLastStep >= adjustedStepInterval then
		-- Emette una particella per l'effetto base
		-- English: Emit one particle for the base effect.
		if isLeftFootTurn then
			baseLeftEmitter:Emit(1)
			-- Emette una particella per la sabbia solo su terreno "Snow"
			-- English: Emit sand particles only on "Snow" terrain.
			if terrainMaterial == "Snow" then
				SnowEffectLeft:Emit(50)
			end
		else
			baseRightEmitter:Emit(1)
			-- Emette una particella per la sabbia solo su terreno "Snow"
			-- English: Emit sand particles only on "Snow" terrain.
			if terrainMaterial == "Snow" then
				SnowEffectRight:Emit(50)
			end
		end

		isLeftFootTurn = not isLeftFootTurn
		timeSinceLastStep = 0
	end
end)

script.Destroying:Connect(function()
	heartbeat:Disconnect()
	for _, emitter in {baseLeftEmitter, baseRightEmitter, SnowEffectLeft, SnowEffectRight} do emitter:Destroy() end
end)
