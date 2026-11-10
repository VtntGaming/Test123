--[[=^.^=]]--
local RunService = game:GetService("RunService")
local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")

-- Disabilita il suono predefinito di footsteps
-- English: Disable the default footstep sound.
local runningSound = humanoidRootPart:FindFirstChild("Running")
if runningSound then runningSound.SoundId, runningSound.Volume = "", 0 end

-- Crea un unico oggetto Sound per i footsteps personalizzati
-- English: Create a single Sound object for custom footsteps.
local footstepSound = Instance.new("Sound", humanoidRootPart)
footstepSound.Name = "FootstepSound"
footstepSound.Looped = true
footstepSound.SoundGroup = game.SoundService:WaitForChild("SFX")

local footstepsounds = script:WaitForChild("FootstepSounds") -- Cartella con i suoni
-- English: Folder containing the sounds.
local currentMaterial, isWalking, walkSpeed = "Air", false, humanoid.WalkSpeed
local defaultSoundId = "rbxasset://sounds/action_footsteps_plastic.mp3"

-- Aggiorna il suono in base al materiale
-- English: Update the sound based on the material.
local function updateFootstepSound(material)
	local soundTemplate = footstepsounds:FindFirstChild(material)
	footstepSound.SoundId = soundTemplate and soundTemplate.SoundId or defaultSoundId
	footstepSound.PlaybackSpeed = walkSpeed / 14
	footstepSound.Volume = 1
end

-- Rileva movimento e aggiorna WalkSpeed
-- English: Detect movement and update WalkSpeed.
humanoid.Running:Connect(function(speed)
	isWalking = character:GetAttribute("IsRagdolled") ~= true and character:GetAttribute("IsFrozen") ~= true and speed > walkSpeed / 2
	if isWalking then
		if not footstepSound.IsPlaying then footstepSound:Play() end
	elseif footstepSound.IsPlaying then
		footstepSound:Stop()
	end
end)
humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
	walkSpeed = humanoid.WalkSpeed
	if isWalking then footstepSound.PlaybackSpeed = walkSpeed / 12 end
end)

-- Logica ottimizzata per Heartbeat
-- English: Optimized logic for Heartbeat.
local heartbeat = RunService.Heartbeat:Connect(function()
	if character:GetAttribute("IsRagdolled") or character:GetAttribute("IsFrozen") then
		isWalking = false
		if footstepSound.IsPlaying then footstepSound:Stop() end
		return
	end
	if not isWalking then return end -- Esci subito se non sta camminando
	-- English: Return immediately if the character is not walking.

	local material = humanoid.FloorMaterial.Name
	if material == "Air" then
		if footstepSound.IsPlaying then footstepSound:Stop() end
		return
	end

	if material ~= currentMaterial then
		currentMaterial = material
		updateFootstepSound(material)
	end
end)

script.Destroying:Connect(function() heartbeat:Disconnect(); footstepSound:Destroy() end)
