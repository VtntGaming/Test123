local CombatController = {}
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local Shared = ReplicatedStorage:WaitForChild("SharedModules")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local WeaponConfig = require(Shared:WaitForChild("WeaponConfig"))
local JumpAttackCharge = require(Shared:WaitForChild("JumpAttackCharge"))
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local Gameplay = require(script.Parent:WaitForChild("GameplayController"))
local Effect = require(script:WaitForChild("Effect"))
local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateSettingEvent = Events:WaitForChild("UpdateSettingEvent")
local AttackEvent = Events:WaitForChild("CombatAttack")
local AbilityEvent = Events:WaitForChild("ActivateAbilityEvent")
local KOEvent = Events:WaitForChild("KOEvent")
local player = Players.LocalPlayer :: Player
local SFX = SoundService:WaitForChild("SFX")
local initialized = false
local defaultFov = 70
local attackCounter, abilityCounter, movementVersion = 0, 0, 0
local nextReady, activeAttackId = 0, 0
local charge, attackTrack, idleTrack, chargeConnection = nil, nil, nil, nil
local activeAbility, chargeTween = nil, nil
local abilityReady, characterConnections, bagEffects = {}, {}, {}
local ui = { Cooldown = nil, AbilityCooldown = nil, ChargeContainer = nil, ChargeGradient = nil }
local cameraTween
local swingSounds: {Sound} = {SFX:WaitForChild("WeaponSwing"), SFX:WaitForChild("WeaponSwing2"), SFX:WaitForChild("WeaponSwing3")}

local KOController = require(script.Parent:WaitForChild("KOController"))

local SmashEffect = require(script.Smash:WaitForChild("SmashEffect"))
local SmashClient = require(script.Smash:WaitForChild("SmashClient"))

local ChargeEffect = require(script.Charge:WaitForChild("ChargeEffect"))
local ChargeClient = require(script.Charge:WaitForChild("ChargeClient"))

local ThrowEffect = require(script.Throw:WaitForChild("ThrowEffect"))
local ThrowClient = require(script.Throw:WaitForChild("ThrowClient"))

local PushEffect = require(script.Push:WaitForChild("PushEffect"))
local PushClient = require(script.Push:WaitForChild("PushClient"))

local PullEffect = require(script.Pull:WaitForChild("PullEffect"))
local PullClient = require(script.Pull:WaitForChild("PullClient"))

local TimeStopEffect = require(script.TimeStop:WaitForChild("TimeStopEffect"))
local TimeStopClock = require(Shared:WaitForChild("TimeStopClock"))

local TimeTravelEffect = require(script.TimeTravel:WaitForChild("TimeTravelEffect"))
local BigWeaponEffect = require(script.BigWeapon:WaitForChild("BigWeaponEffect"))

local InvisibleEffect = require(script.Invisible.InvisibleEffect)
local ShieldEffect = require(script.ShieldEffect)
local ShrinkEffect = require(script.Shrink.ShrinkEffect)

local ChargeVfx = require(script:WaitForChild("ChargeVFX"))
local function triggerUI(element, duration)
	if not element then return end
	element.Size = UDim2.new(0, 0, 1, 0)
	TweenService:Create(element, TweenInfo.new(math.max(0.01, duration), Enum.EasingStyle.Linear), { Size = UDim2.new(1, 0, 1, 0) }):Play()
end

local function setFov(value, duration)
	local camera = Workspace.CurrentCamera
	if not camera then return end
	if cameraTween then cameraTween:Cancel() end
	cameraTween = TweenService:Create(camera, TweenInfo.new(duration), { FieldOfView = value })
	cameraTween:Play()
end

local function characterBlocked(character)
	return not character or player.Character ~= character or not character.Parent
		or character:GetAttribute("IsRagdolled") or character:GetAttribute("IsFrozen")
		or character:GetAttribute("MovementLocked") or player:GetAttribute("IsFrozen")
		or player:GetAttribute("TeleportingActive")
end

local function inCombatZone()
	return player:GetAttribute("IsOnArena") or player:GetAttribute("IsInTrainingArea")
end

local function stopTrack(track, fade)
	if not track then return end
	track:Stop(fade or 0)
	task.delay((fade or 0) + 0.05, function() track:Destroy() end)
end

local function loadWeaponTrack(character, weaponId, slot): AnimationTrack?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local info = WeaponConfig.BaseWeapons[weaponId]
	if not animator or not info then return nil end
	local animation = Instance.new("Animation")
	local settings = info[slot]
	animation.Name, animation.AnimationId = slot, if slot == "Idle" then settings else settings.AnimationId
	animation:SetAttribute("CombatWeaponAnimation", true)
	animation:SetAttribute("BaseWeaponId", weaponId)
	local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
	animation:Destroy()
	return ok and track or nil
end

local function hideCharge(current)
	ChargeVfx.Stop()
	if current then
		if current.airConnection then current.airConnection:Disconnect(); current.airConnection = nil end
		JumpAttackCharge.Stop(current.airMotion)
	end
	if chargeConnection then chargeConnection:Disconnect(); chargeConnection = nil end
	if chargeTween then chargeTween:Cancel(); chargeTween = nil end
	if ui.ChargeContainer then ui.ChargeContainer.Visible = false end
	if ui.ChargeGradient then ui.ChargeGradient.Offset = Vector2.new(-1, 0) end
	Gameplay.StopChargeFeedback()
end

local function cancelAttack(notifyServer)
	local pending = charge
	charge = nil
	if notifyServer then
		local character = pending and pending.character or player.Character
		local id = pending and pending.id or activeAttackId
		if character and id > 0 then
			-- The latest attack ID also cancels a released swing without waiting for an acknowledgement.
			AttackEvent:FireServer(
				"Cancel",
				id,
				character,
				pending and pending.generation or character:GetAttribute("RagdollGeneration"),
				pending and pending.equipmentRevision or character:GetAttribute("WeaponRevision") or 0
			)
		end
	end
	hideCharge(pending)
	if attackTrack then local old = attackTrack; attackTrack = nil; stopTrack(old, 0.05) end
	Gameplay.SetCrosshair("Default")
end

local function cancelAbility(rollback)
	local ability = activeAbility
	activeAbility = nil
	if not ability then return end
	if ability.velocity then ability.velocity:Destroy() end
	if ability.attachment then ability.attachment:Destroy() end
	if rollback and ability.previousVelocity and ability.root.Parent and not characterBlocked(ability.character) and not ability.root.Anchored then
		ability.root.AssemblyLinearVelocity = ability.previousVelocity
	end
	if ability.cleanup then ability.cleanup() end
	if ability.velocity then ability.velocity:Destroy() end
end

function CombatController.CancelMovement(character)
	if character and character ~= player.Character then return end
	movementVersion += 1
	cancelAttack(true)
	cancelAbility(false)
	setFov(defaultFov, 0.2)
end

local function updateIdle()
	if idleTrack then local old = idleTrack; idleTrack = nil; stopTrack(old, 0.15) end
	local character, weapon = player.Character, player:GetAttribute("EquippedBaseWeapon")
	if characterBlocked(character) or not inCombatZone() or not weapon then return end
	local equipped = character:FindFirstChild("EquippedWeapon")
	if not equipped then return end
	idleTrack = loadWeaponTrack(character, weapon, "Idle")
	if idleTrack then
		idleTrack.Priority, idleTrack.Looped = Enum.AnimationPriority.Idle, true
		idleTrack:Play(0.2)
	end
end

local function spawnDashHologram(character)
	if not character or not character.Parent then return end
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "CombatDashEffect", Workspace.Terrain
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 and part.Name ~= "HumanoidRootPart" then
			local clone = part:Clone()
			for _, child in clone:GetChildren() do if not child:IsA("SpecialMesh") then child:Destroy() end end
			clone.Anchored, clone.CanCollide, clone.CanTouch, clone.CanQuery, clone.Massless = true, false, false, false, true
			clone.Material, clone.Transparency, clone.CFrame, clone.Parent = Enum.Material.Neon, 0.4, part.CFrame, folder
			TweenService:Create(clone, TweenInfo.new(0.35), { Transparency = 1 }):Play()
		end
	end
	Debris:AddItem(folder, 0.4)
end

local dashSound = SoundService:WaitForChild("SFX"):WaitForChild("Dash") :: Sound
local function dashVisuals(character, valid)
	task.spawn(function()
		local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
		if root then
			local sound = root:FindFirstChild("Dash") :: Sound
			if not sound then
				sound = dashSound:Clone()
				sound.Looped = false
				sound.Name = "Dash"
				sound.Parent = root
			end
			sound:Play()
		end
		local untilTime = os.clock() + AbilityConfig.Abilities.Dash.Duration
		repeat
			if not character.Parent or character:GetAttribute("IsRagdolled") or (valid and not valid()) then return end
			spawnDashHologram(character)
			task.wait(0.04)
		until os.clock() >= untilTime
	end)
end

local function useAbility(abilityName)
	local character = player.Character
	local config = type(abilityName) == "string" and AbilityConfig.Abilities[abilityName]
	if
		not config
		or characterBlocked(character)
		or not inCombatZone()
		or charge
		or attackTrack
		or (activeAbility and activeAbility.name == "Charge" and not activeAbility.finished)
	then
		return
	end
	if Workspace:GetServerTimeNow() < (abilityReady[abilityName] or 0) then return end
	local root, humanoid = character:FindFirstChild("HumanoidRootPart"), character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or root.Anchored or not humanoid then return end
	if abilityName ~= "Dash" and abilityName ~= "MegaJump" and abilityName ~= "Shrink" 
		and abilityName ~= "Invisible" and abilityName ~= "Smash" and abilityName ~= "Charge" 
		and abilityName ~= "Throw" and abilityName ~= "Push" and abilityName ~= "Pull"
		and abilityName ~= "TimeStop" and abilityName ~= "BigWeapon" and abilityName ~= "TimeTravel"
		and abilityName ~= "ShadowClone" and abilityName ~= "Shield" then return end
	
	-- if abilityName == "Charge" and humanoid.FloorMaterial == Enum.Material.Air then return end
	if abilityName == "Smash" and humanoid.FloorMaterial == Enum.Material.Air then return end

	if abilityName == "TimeTravel" then
		-- two-step ability: the server decides if this press drops the ghost or jumps back to it.
		-- The HUD cooldown starts when the server says the ability ended ("TimeTravelCooldown").
		abilityCounter += 1
		AbilityEvent:FireServer("Request", abilityCounter, abilityName, character, character:GetAttribute("RagdollGeneration"))
		return
	end
	
	cancelAbility(false)
	abilityCounter += 1
	local action = { id = abilityCounter, character = character, root = root, name = abilityName, version = movementVersion, confirmed = false, finished = false }
	activeAbility = action
	abilityReady[abilityName] = Workspace:GetServerTimeNow() + config.Cooldown
	triggerUI(ui.AbilityCooldown, config.Cooldown)
	AbilityEvent:FireServer("Request", action.id, abilityName, character, character:GetAttribute("RagdollGeneration"))
	if abilityName == "Dash" then
		local direction = humanoid.MoveDirection.Magnitude > 0.01 and humanoid.MoveDirection.Unit or root.CFrame.LookVector
		local attachment, velocity = Instance.new("Attachment"), Instance.new("LinearVelocity")
		attachment.Name, attachment.Parent = "AbilityAttachment", root
		velocity.Name, velocity.Attachment0, velocity.RelativeTo = "AbilityVelocity", attachment, Enum.ActuatorRelativeTo.World
		velocity.MaxForce, velocity.VectorVelocity, velocity.Parent = 999999, direction * config.Velocity, root
		action.attachment, action.velocity = attachment, velocity
		setFov(85, 0.1)
		dashVisuals(character, function() return activeAbility == action and action.version == movementVersion end)
	elseif abilityName == "MegaJump" then
		action.previousVelocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(action.previousVelocity.X, config.Force, action.previousVelocity.Z)
	elseif abilityName == "Smash" then
		action.cleanup = SmashClient.Start({
			config = config, character = character, root = root, humanoid = humanoid,
			defaultFov = defaultFov, setFov = setFov,
			alive = function()
				return activeAbility == action and action.version == movementVersion
					and root.Parent ~= nil and not characterBlocked(character)
			end,
			onImpact = function(position)
				AbilityEvent:FireServer("Impact", action.id, "Smash", character, character:GetAttribute("RagdollGeneration"), position)
			end,
			onFinish = function()
				if activeAbility == action then
					if action.confirmed then activeAbility = nil else action.finished = true end
				end
			end,
		})
		return -- Smash manages its own timing, skip the generic Duration timer below
	
	elseif abilityName == "Charge" then
		action.cleanup = ChargeClient.Start({
			config = config, character = character, root = root, humanoid = humanoid,
			defaultFov = defaultFov, setFov = setFov,
			alive = function()
				return activeAbility == action and action.version == movementVersion
					and root.Parent ~= nil and not characterBlocked(character)
			end,
		})
	elseif abilityName == "Throw" then
		local aim = ThrowClient.GetAim() or (root.CFrame.LookVector * Vector3.new(1, 0, 1)).Unit
		action.cleanup = ThrowClient.Start({
			config = config, character = character, root = root, humanoid = humanoid,
			defaultFov = defaultFov, setFov = setFov, aim = aim,
			alive = function()
				return activeAbility == action and action.version == movementVersion
					and root.Parent ~= nil and not characterBlocked(character)
			end,
		})
		-- Send the aim direction in place of the position argument
		AbilityEvent:FireServer("Request", action.id, abilityName, character, character:GetAttribute("RagdollGeneration"), aim)
		return
			-- Add Push logic branch:
	elseif abilityName == "Push" then
		local camera = Workspace.CurrentCamera
		local aim = camera and camera.CFrame.LookVector
		aim = aim and Vector3.new(aim.X, 0, aim.Z).Unit or root.CFrame.LookVector

		action.cleanup = PushClient.Start({
			config = config, character = character, root = root, humanoid = humanoid,
			defaultFov = defaultFov, setFov = setFov, aim = aim,
			alive = function()
				return activeAbility == action and action.version == movementVersion
					and root.Parent ~= nil and not characterBlocked(character)
			end,
		})
		AbilityEvent:FireServer("Request", action.id, abilityName, character, character:GetAttribute("RagdollGeneration"), aim)
		return

			-- Add Pull logic branch:
	elseif abilityName == "Pull" then
		local camera = Workspace.CurrentCamera
		local aim = camera and camera.CFrame.LookVector
		aim = aim and Vector3.new(aim.X, 0, aim.Z).Unit or root.CFrame.LookVector

		action.cleanup = PullClient.Start({
			config = config, character = character, root = root, humanoid = humanoid,
			defaultFov = defaultFov, setFov = setFov, aim = aim,
			alive = function()
				return activeAbility == action and action.version == movementVersion
					and root.Parent ~= nil and not characterBlocked(character)
			end,
		})
		AbilityEvent:FireServer("Request", action.id, abilityName, character, character:GetAttribute("RagdollGeneration"), aim)
		return	
	elseif abilityName == "ShadowClone" then
		-- the server summons and drives the clones; the client only asks (cooldown HUD already started above)
		action.finished = true
		AbilityEvent:FireServer("Request", action.id, abilityName, character, character:GetAttribute("RagdollGeneration"))
		return
	elseif abilityName == "TimeStop" then
		AbilityEvent:FireServer("Request", action.id, abilityName, character, character:GetAttribute("RagdollGeneration"))
		return

			
	end
	
	task.delay(config.Duration or 0.25, function()
		if activeAbility == action then
			if action.velocity then action.velocity:Destroy(); action.velocity = nil end
			if action.attachment then action.attachment:Destroy(); action.attachment = nil end
			setFov(defaultFov, 0.25)
			-- Keep the token until its result arrives so a delayed rejection can still cancel.
			if action.confirmed then activeAbility = nil else action.finished = true end
		end
	end)
end

local function startCharge()
	local character, weapon = player.Character, player:GetAttribute("EquippedBaseWeapon")
	if
		characterBlocked(character)
		or not inCombatZone()
		or not weapon
		or charge
		or attackTrack
		or Workspace:GetServerTimeNow() < nextReady
		or (activeAbility and activeAbility.name == "Charge" and not activeAbility.finished)
	then
		return
	end
	local equipped = character:FindFirstChild("EquippedWeapon")
	local generation = character:GetAttribute("RagdollGeneration")
	if not equipped or not generation then return end
	attackCounter += 1
	activeAttackId = attackCounter
	local current = {
		id = attackCounter, character = character, generation = generation,
		equipmentRevision = character:GetAttribute("WeaponRevision") or 0, started = os.clock(),
		startedAt = Workspace:GetServerTimeNow(),
		cooldown = WeaponConfig.BaseWeapons[weapon].Cooldown
			* (if character:GetAttribute("TimeStopActive") then (AbilityConfig.Abilities.TimeStop.AttackCooldownScale or 1) else 1),
	}
	charge = current
	ChargeVfx.Start(character, GameConfig.Combat.MaxChargeTime)   
	current.airMotion = JumpAttackCharge.Begin(character)
	current.attackType = if current.airMotion.airborne then "JumpAttack" else "Attack"
	if WeaponConfig.ChargedJumpAttack.Enable and current.airMotion.airborne then
		current.airConnection = RunService.Heartbeat:Connect(function()
			if charge == current and not characterBlocked(character) then
				JumpAttackCharge.Update(current.airMotion, os.clock() - current.started)
			end
		end)
	end
	AttackEvent:FireServer("Start", current.id, character, generation, current.equipmentRevision,
		current.startedAt, current.attackType)
	Gameplay.StartChargeFeedback()
	if ui.ChargeGradient then
		ui.ChargeGradient.Offset = Vector2.new(-1, 0)
		chargeTween = TweenService:Create(ui.ChargeGradient, TweenInfo.new(GameConfig.Combat.MaxChargeTime, Enum.EasingStyle.Linear), { Offset = Vector2.zero })
		chargeTween:Play()
		task.delay(0.5, function() if charge == current and ui.ChargeContainer then ui.ChargeContainer.Visible = true end end)
	end
	attackTrack = loadWeaponTrack(character, weapon, current.attackType)
	local track = attackTrack
	if not track then return end
	track.Priority, track.Looped = Enum.AnimationPriority.Action, false
	track:Play()

	local chargeThreshold = 0.4
	local info = WeaponConfig.BaseWeapons[weapon]
	if info then
		local attack = info[current.attackType]
		chargeThreshold = attack.TrackChargeThreshold or chargeThreshold
	end

	chargeConnection = RunService.Heartbeat:Connect(function()
		if charge ~= current or attackTrack ~= track then
			if chargeConnection then chargeConnection:Disconnect(); chargeConnection = nil end
			return
		end
		if track.Length <= 0 then return end
		local targetTime = track.Length * chargeThreshold
		if track.TimePosition >= targetTime then
			track:AdjustSpeed(0)
			track.TimePosition = targetTime
		else
			track:AdjustSpeed(math.clamp(1 - track.TimePosition / math.max(targetTime, 0.01), 0.1, 1))
		end
	end)
end

local function releaseCharge()
	local current = charge
	if not current then return end
	charge = nil
	hideCharge(current)
	if characterBlocked(current.character) then
		AttackEvent:FireServer("Cancel", current.id, current.character, current.generation, current.equipmentRevision)
		cancelAttack(false)
		return
	end
	-- Finalize charge immediately; the server owns wind-up and the active hit window.
	local releasedAt = Workspace:GetServerTimeNow()
	local cooldown = current.cooldown
	nextReady = releasedAt + cooldown
	AttackEvent:FireServer(
		"Release",
		current.id,
		current.character,
		current.generation,
		current.equipmentRevision,
		releasedAt,
		os.clock() - current.started
	)
	triggerUI(ui.Cooldown, cooldown)
	Gameplay.SetCrosshair("Loading")
	task.delay(cooldown, function() if activeAttackId == current.id then Gameplay.SetCrosshair("Default") end end)
	local track = attackTrack
	if track then
		track:AdjustSpeed(1)
		local sound = swingSounds[math.random(1, #swingSounds)]
		if sound then sound:Play() end
		track.Stopped:Once(function()
			if attackTrack == track then attackTrack = nil end
			track:Destroy()
		end)
		task.delay(3, function()
			if attackTrack == track then attackTrack = nil; stopTrack(track, 0.05) end
		end)
	end
end
local function beginAttackInput()
    local character = player.Character
    local humanoid = character
        and character:FindFirstChildOfClass("Humanoid")

    if not humanoid then return end

    local isInAir = humanoid.FloorMaterial == Enum.Material.Air
    local previousCharge = charge

    startCharge()

    -- With jump charging disabled, a press performs a normal jump attack immediately.
    if isInAir and not WeaponConfig.ChargedJumpAttack.Enable and charge and charge ~= previousCharge then
        releaseCharge()
    end
end
local function clearBagEffect(bag)
	local effect = bagEffects[bag]
	if not effect then return end
	bagEffects[bag] = nil
	if effect.tween then effect.tween:Cancel() end
	if effect.connection then effect.connection:Disconnect() end
	if effect.resetConnection then effect.resetConnection:Disconnect() end
	if effect.generationConnection then effect.generationConnection:Disconnect() end
	if bag.Parent then
		bag.Size = effect.size
		if effect.face and bag:IsA("MeshPart") then bag.TextureID = effect.face end
	end
end

local function bagHit(bag, generation, revision)
	if typeof(bag) ~= "Instance" or not bag:IsA("BasePart") or not bag.Parent then return end
	if bag:GetAttribute("RagdollGeneration") ~= generation then return end
	clearBagEffect(bag)
	local effect = { size = bag.Size, face = bag:IsA("MeshPart") and bag.TextureID or nil, revision = revision }
	bagEffects[bag] = effect
	local face1, face2, face3 = bag:GetAttribute("Face1"), bag:GetAttribute("Face2"), bag:GetAttribute("Face3")
	if bag:IsA("MeshPart") and face1 and face2 and face3 then
		effect.face = face1
		bag.TextureID = math.random() > 0.5 and face2 or face3
	end
	effect.tween = TweenService:Create(bag, TweenInfo.new(0.15, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out, 0, true), { Size = effect.size * Vector3.new(1.2, 0.7, 1.2) })
	effect.tween:Play()
	effect.connection = bag.AncestryChanged:Connect(function() if not bag:IsDescendantOf(Workspace) then clearBagEffect(bag) end end)
	effect.resetConnection = bag:GetAttributeChangedSignal("MovementRevision"):Connect(function() clearBagEffect(bag) end)
	effect.generationConnection = bag:GetAttributeChangedSignal("RagdollGeneration"):Connect(function() clearBagEffect(bag) end)
	task.delay(1.5, function() if bagEffects[bag] == effect then clearBagEffect(bag) end end)
end

local function attachCharacter(character)
	for _, connection in characterConnections do connection:Disconnect() end
	table.clear(characterConnections)
	CombatController.CancelMovement()
	updateIdle()
	local function changed()
		if characterBlocked(character) then
			CombatController.CancelMovement(character)
			if idleTrack then local old = idleTrack; idleTrack = nil; stopTrack(old, 0.05) end
		else updateIdle() end
	end
	for _, attribute in { "IsRagdolled", "IsFrozen", "MovementLocked" } do
		table.insert(characterConnections, character:GetAttributeChangedSignal(attribute):Connect(changed))
	end
	for _, attribute in { "MovementRevision", "WeaponRevision", "RagdollGeneration" } do
		table.insert(characterConnections, character:GetAttributeChangedSignal(attribute):Connect(function()
			CombatController.CancelMovement(character)
			updateIdle()
		end))
	end
	table.insert(characterConnections, character.ChildAdded:Connect(function(child)
		if child.Name == "EquippedWeapon" then updateIdle() end
	end))
	table.insert(characterConnections, character.DescendantAdded:Connect(function(child)
		if child:IsA("Animator") then updateIdle() end
	end))
end
local function stopCrowdCheer()
	local cheer = SFX:FindFirstChild("CrowdCheer")
	if not cheer or not cheer:IsA("Sound") or not cheer.IsPlaying then return end
	local original = cheer:GetAttribute("OriginalVolume") or cheer.Volume
	cheer:SetAttribute("OriginalVolume", original)
	local fade = TweenService:Create(cheer, TweenInfo.new(0.12), { Volume = 0 })
	fade.Completed:Once(function()
		cheer:Stop()
		cheer.Volume = original
	end)
	fade:Play()
end

local function waitForSound(sound: Sound?, timeout: number)
	if not sound then return end
	local startedAt = os.clock()
	task.wait(0.05) -- let IsPlaying turn true
	while sound.IsPlaying and os.clock() - startedAt < timeout do
		task.wait(0.05)
	end
end


local function playHitSoundCopy(source: Sound)
	local copy = source:Clone()
	copy.Looped = false
	copy.Parent = SoundService
	copy.Ended:Once(function() copy:Destroy() end)
	Debris:AddItem(copy, 5)
	copy:Play()
end

local function playHitSound(character: Model, weaponId: string, soundName: string?)
	if type(soundName) ~= "string" then return end

	-- a) Sound inside the equipped weapon (any depth, any part name)
	local equipped = character:FindFirstChild("EquippedWeapon")
	if WeaponConfig.WeaponEffectSoundEnabled then
		local effectSound = equipped and equipped:FindFirstChild("WeaponEffectHit", true)
		if effectSound and effectSound:IsA("Sound") then
			effectSound:Play()
		else
			-- Match the normal hit sound's local fallback while the attached sound is replicating.
			local name = equipped and equipped:GetAttribute("WeaponName")
			local info = if type(name) == "string" then WeaponConfig.GetWeaponInfo(name) else nil
			local assets = ReplicatedStorage:FindFirstChild("Assets")
			local sfx = assets and assets:FindFirstChild("SFX")
			local library = sfx and sfx:FindFirstChild("WeaponEffects")
			local source = info and library and library:FindFirstChild(info.Variant)
			if source and source:IsA("Sound") then playHitSoundCopy(source) end
		end
	end
	local own = equipped and equipped:FindFirstChild(soundName, true)
	if own and own:IsA("Sound") then
		own:Play()
		return
	end

	-- b) Weapon variants have no hit sound: fall back to the base weapon's sound
	--    (ReplicatedStorage.Assets.Weapons.<weaponId>)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local templates = assets and assets:FindFirstChild("Weapons")
	local template = templates and templates:FindFirstChild(weaponId)
	local source = template and template:FindFirstChild(soundName, true)
	if source and source:IsA("Sound") then
		playHitSoundCopy(source)
	end
end


function CombatController.Init()
	if initialized then return end
	initialized = true
	Effect.Init()
	SmashEffect.Init(Gameplay.TriggerPresetShake)
	ChargeEffect.Init(Gameplay.TriggerPresetShake)
	ThrowEffect.Init()
	TimeStopEffect.Init(Gameplay.TriggerPresetShake)
	TimeTravelEffect.Init(Gameplay.TriggerPresetShake)
	BigWeaponEffect.Init(Gameplay.TriggerPresetShake)	
	InvisibleEffect.Init()
	ShieldEffect.Init()
	ShrinkEffect.Init()
	
	local camera = Workspace.CurrentCamera
	if camera then defaultFov = camera.FieldOfView end
	local mainGui = player:WaitForChild("PlayerGui"):WaitForChild("MainGui") :: ScreenGui
	mainGui.Enabled = true
	local hud = mainGui:WaitForChild("HUD")
	local cooldown = hud:WaitForChild("CooldownBar", 3)
	local abilityCooldown = hud:WaitForChild("AbilityCooldownBar", 3)
	ui.Cooldown = cooldown and cooldown:FindFirstChild("Fill")
	ui.AbilityCooldown = abilityCooldown and abilityCooldown:FindFirstChild("Fill")
	ui.ChargeContainer = hud:WaitForChild("ChargeBarContainer", 3)
	if ui.ChargeContainer then
		ui.ChargeContainer.Visible = false
		ui.ChargeGradient = ui.ChargeContainer:WaitForChild("Ring"):WaitForChild("UIStroke"):WaitForChild("UIGradient")
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then beginAttackInput()
		elseif input.KeyCode == Enum.KeyCode.E then useAbility(player:GetAttribute("EquippedAbility")) end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then releaseCharge() end
	end)
	UserInputService.WindowFocusReleased:Connect(function() cancelAttack(true) end)
	local buttons = mainGui:WaitForChild("PhoneButtons", 5)
	if buttons then
		local function valid(input) return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 end
		local function bindAttack(btn: GuiButton)
			btn.InputBegan:Connect(function(input) if valid(input) then beginAttackInput() end end)
			btn.InputEnded:Connect(function(input) if valid(input) then releaseCharge() end end)
		end

		for _, item in buttons:WaitForChild("AttackButton"):GetChildren() do
			if item:IsA("GuiButton") then
				bindAttack(item)
			end
		end

		local function bindAbility(btn: GuiButton)
			btn.InputBegan:Connect(function(input) if valid(input) then useAbility(player:GetAttribute("EquippedAbility")) end end)
		end

		for _, item in buttons:WaitForChild("AbilityButton"):GetChildren() do
			if item:IsA("GuiButton") then
				bindAbility(item)
			end
		end
	end
	for _, attribute in { "EquippedBaseWeapon", "IsOnArena", "IsInTrainingArea", "IsFrozen", "TeleportingActive" } do
		player:GetAttributeChangedSignal(attribute):Connect(function()
			if characterBlocked(player.Character) or not inCombatZone() then CombatController.CancelMovement() end
			updateIdle()
		end)
	end
	-- Start visual UI cooldown when entering the arena
	player:GetAttributeChangedSignal("IsOnArena"):Connect(function()
		if player:GetAttribute("IsOnArena") then
			local ability = player:GetAttribute("EquippedAbility")
			local config = ability and AbilityConfig.Abilities[ability]
			if config then
				abilityReady[ability] = Workspace:GetServerTimeNow() + config.Cooldown
				triggerUI(ui.AbilityCooldown, config.Cooldown)
			end
		end
	end)

	player.CharacterAdded:Connect(attachCharacter)
	player.CharacterRemoving:Connect(function(character)
		CombatController.CancelMovement(character)
		if idleTrack then local old = idleTrack; idleTrack = nil; stopTrack(old, 0) end
		for _, connection in characterConnections do connection:Disconnect() end
		table.clear(characterConnections)
	end)
	if player.Character then attachCharacter(player.Character) end
	UpdateSettingEvent:FireServer("Hardware", UserInputService.GamepadEnabled and "Controller" or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and "Mobile" or "PC"))
	AttackEvent.OnClientEvent:Connect(function(action, a, b, c, d, e)
		if action == "BagHit" then bagHit(a, b, c)
		elseif action == "Rejected" and a == activeAttackId then
			cancelAttack(false)
			if type(c) == "number" then nextReady = c end
		elseif action == "Hits" and b == player.Character and b:GetAttribute("RagdollGeneration") == c and a == activeAttackId and type(e) == "table" and #e > 0 then
			setFov(80, 0.1)
			local version = movementVersion
			task.delay(0.15, function() if version == movementVersion then setFov(defaultFov, 0.15) end end)
			Gameplay.SetCrosshair("Hit")
			Gameplay.TriggerPresetShake("Bump")
			local info = WeaponConfig.BaseWeapons[d]
			if info then playHitSound(b, d, info.HitSound) end
		end
	end)
	AbilityEvent.OnClientEvent:Connect(function(action, a, b, c, d)
		if action == "SmashStart" then
			-- a = smasher (Player), b = character, c = radius
			if typeof(b) == "Instance" and type(c) == "number" then SmashEffect.StartTelegraph(a, b, c) end
		elseif action == "SmashEnd" then
			SmashEffect.StopTelegraph(a)
		elseif action == "SmashImpact" then
			-- a = ground point, b = radius, c = smasher (Player). The smasher already played it locally.
			SmashEffect.StopTelegraph(c)
			SmashEffect.Impact(a, b, c and c.Character, false)
		elseif action == "SmashResult" then
			if type(b) == "number" and b > 0 then Gameplay.SetCrosshair("Hit") end
		elseif action == "ChargeStart" then
			-- a = charger (Player), b = character, c = duration
			if typeof(b) == "Instance" and type(c) == "number" then ChargeEffect.Start(a, b, c) end
		elseif action == "ChargeEnd" then
			ChargeEffect.Stop(a)
		elseif action == "ChargeImpact" then
			-- a = charger (Player), b = hit position
			ChargeEffect.Impact(a, b)
		elseif action == "ChargeHit" then
			-- only the charger: a = how many he hit so far
			if type(a) == "number" then ChargeEffect.ChargerHit(a) end
			Gameplay.SetCrosshair("Hit")
		elseif action == "ChargeVictim" then
			-- only the player that got plowed through
			ChargeEffect.Victim()
		elseif action == "ThrowStart" then
			-- a = thrower (Player), b = character, c = params
			ThrowEffect.Launch(a, b, c)
		elseif action == "ThrowImpact" then
			-- a = thrower (Player), b = position
			ThrowEffect.Impact(a, b)
		elseif action == "ThrowHit" then
			-- a = hits count
			if type(a) == "number" then ThrowEffect.ThrowerHit(a) end
			Gameplay.SetCrosshair("Hit")
		elseif action == "ThrowVictim" then
			ThrowEffect.Victim()
			-- Push listeners
		elseif action == "PushStart" then
			PushEffect.Cast(a, b, c) -- a = Player, b = Character, c = params
		elseif action == "PushImpact" then
			PushEffect.Impact(a, b) -- a = Player, b = Position
		elseif action == "PushHit" then
			if type(a) == "number" then PushEffect.PusherHit(a) end
			Gameplay.SetCrosshair("Hit")
		elseif action == "PushVictim" then
			PushEffect.Victim()

			-- Pull listeners
		elseif action == "PullStart" then
			PullEffect.Cast(a, b, c) -- a = Player, b = Character, c = params
		elseif action == "PullHook" then
			PullEffect.Hook(a, b, c) -- a = Player, b = Target, c = StopPoint
		elseif action == "PullHit" then
			if type(a) == "number" then PullEffect.PullerHit(a) end
			Gameplay.SetCrosshair("Hit")
		elseif action == "PullVictim" then
			PullEffect.Victim()

		elseif action == "Visual" then
			if a ~= player and b == "Dash" and typeof(c) == "Instance" then dashVisuals(c) end
		elseif action == "Cancel" then
			if (not a or a == player.Character) and activeAbility and activeAbility.id <= b then cancelAbility(false); setFov(defaultFov, 0.2) end
		elseif action == "Result" then
			local ability = activeAbility
			if not ability or ability.id ~= a then return end
			if type(d) == "number" then abilityReady[c] = d; triggerUI(ui.AbilityCooldown, math.max(0, d - Workspace:GetServerTimeNow())) end
			if not b then cancelAbility(true); setFov(defaultFov, 0.2)
			else ability.confirmed = true; if ability.finished then activeAbility = nil end end
		elseif action == "TimeStopReady" then
			TimeStopEffect.Ready(a, b, c)
		elseif action == "TimeStopStart" then
			TimeStopClock.Begin(c.since)
			TimeStopEffect.Start(a, b, c)
		elseif action == "TimeStopMark" then
			TimeStopEffect.Mark(a, b)
		elseif action == "TimeStopHit" then
			TimeStopEffect.Hit(a, b, c)
		elseif action == "TimeStopEnd" then
			TimeStopClock.End(if type(b) == "table" and b.at then b.at else Workspace:GetServerTimeNow())
			TimeStopEffect.End(a, b)
		elseif action == "TimeStopCancel" then
			TimeStopEffect.Cancel(a)
		elseif action == "TimeTravelSet" then
			TimeTravelEffect.Set(a, b, c) -- a = Player, b = Character, c = { cframe, expiresAt, duration }
		elseif action == "TimeTravelReturn" then
			TimeTravelEffect.Return(a, b, c) -- a = Player, b = Character, c = { from, to }
		elseif action == "TimeTravelEnd" then
			TimeTravelEffect.End(a, b) -- a = Player, b = returned
		elseif action == "TimeTravelCooldown" then
			-- only the caster: a = server time when the ability can be used again
			if type(a) == "number" then
				abilityReady.TimeTravel = a
				triggerUI(ui.AbilityCooldown, math.max(0, a - Workspace:GetServerTimeNow()))
			end
		elseif action == "BigWeaponStart" then
			BigWeaponEffect.Start(a, b, c) -- a = Player, b = Character, c = { radius, scale, releaseTime }
		elseif action == "BigWeaponImpact" then
			BigWeaponEffect.Impact(a, b, c) -- a = Player, b = ground centre, c = radius
		elseif action == "BigWeaponEnd" then
			BigWeaponEffect.End(a)
		elseif action == "BigWeaponResult" then
			-- only the caster: a = how many he hit
			if type(a) == "number" and a > 0 then Gameplay.SetCrosshair("Hit") end
		end
		
	end)
	
	

	KOEvent.OnClientEvent:Connect(function(position: Vector3, isDecidingKO: boolean, killerName: string?, victimName: string?, lifeLost: boolean?)
		Gameplay.PlayRandomDeathVFX("KOEffect", CFrame.new(position))

		-- CrowdCheer: only when a life was really lost, and only for the player who landed the hit
		-- and the player who got knocked out. The deciding KO has its own KO sound instead.
		if lifeLost and not isDecidingKO and (killerName == player.Name or victimName == player.Name) then
			local cheer = SFX:FindFirstChild("CrowdCheer")
			if cheer and cheer:IsA("Sound") then
				cheer.TimePosition = 0
				cheer:Play()
			end
		end

		local isKiller = isDecidingKO and killerName == player.Name

		-- The KO voice replaces the normal death sound for the player who landed the final blow.
		if not isKiller then
			local sound = SFX:FindFirstChild("Death")
			if sound then sound:Play() end
		end

		if not isDecidingKO then return end

		task.spawn(function()
			if isKiller then
				-- KO effect + KO sound, only for the killer. Crowd is silenced so nothing stacks.
				SoundService:SetAttribute("KOSequence", true)
				stopCrowdCheer()
				local koSound = KOController.Play()
				waitForSound(koSound, 6) -- GameWin only starts after the KO sound is done
				SoundService:SetAttribute("KOSequence", nil)
			else
				task.wait(0.3) -- let IsOnArena replicate
			end

			-- GameWin only for the survivor that is still on the arena
			if player:GetAttribute("IsOnArena") then
				local win = SFX:FindFirstChild("GameWin")
				if win then win:Play() end
			end
		end)
			--local part = Instance.new("Part")
			--part.Parent = workspace.Terrain
			--part.Anchored = true
			--part.CanCollide = false
			--part.CanQuery = false
			--part.CanTouch = false
			--part.CastShadow = false
			--part.Transparency = 1
			--part.Position = position		
			--sound2.Parent = part
			--sound2:Play()
			--Debris:AddItem(part,sound2.TimeLength)
		
	end)
	
	do -- player charge
		local function OnPlayerAdded(player: Player)
			if player == Players.LocalPlayer :: Player then
				return
			end
			player:GetAttributeChangedSignal("ChargeAttack"):Connect(function(...)
				if not player.Character then
					return
				end
				local isCharge = player:GetAttribute("ChargeAttack")
				if isCharge then
					ChargeVfx.Start(player.Character, GameConfig.Combat.MaxChargeTime)  
				else
					ChargeVfx.Stop(player.Character)  
				end
			end)
		end
		Players.PlayerAdded:Connect(OnPlayerAdded)
		for _,player in ipairs(Players:GetPlayers()) do
			OnPlayerAdded(player)
		end
	end

	--local transparencyDict = {} :: {[Instance]: number}
	--local hasKO = false
	--RunService.Heartbeat:Connect(function()
	--	local character = player.Character
	--	local root = character and character:FindFirstChild("HumanoidRootPart")
	--	if not root or not root:IsA("BasePart") then return end
	--	if root.Position.Y < (GameConfig.VoidHeight or -50) and not hasKO then
	--		do -- anchor and transparency parts
	--			root.Anchored = true
	--			local dict = {}
	--			for _,ins in ipairs(character:GetDescendants()) do
	--				local valid = true
	--				if not (ins:IsA("BasePart") or ins:IsA("Decal")) then
	--					valid = false
	--				end
	--				if valid then
	--					if ins.Transparency then
	--						if ins.Transparency < 1 then
	--							dict[ins] = ins.Transparency
	--							ins.Transparency = 1
	--						end
	--					else
	--						warn(`{ins} of type: {typeof(ins)} has no transparency property`)
	--					end
	--				end
	--			end
	--			transparencyDict = dict
	--		end

	--		hasKO = true
			
	--	elseif root.Position.Y >= (GameConfig.VoidHeight or -50) then 
	--		hasKO = false
	--		local dict = transparencyDict
	--		if dict then
	--			root.Anchored = false
	--			for ins, trans in pairs(dict) do
	--				ins.Transparency = trans
	--			end
	--			transparencyDict = nil
	--		end

	--	end
	--end)
end

return CombatController
