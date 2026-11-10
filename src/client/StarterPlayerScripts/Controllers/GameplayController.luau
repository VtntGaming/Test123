-- Presents camera, input-device and gameplay feedback; shared simulation owns movement and jumping.
local GameplayController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local CollectionService = game:GetService("CollectionService")

local PlayerData = require(ReplicatedStorage.PlayerData)
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local CameraShaker = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("CameraShaker"))
local Events = ReplicatedStorage:WaitForChild("Events")
local SpawnVisualCoinsEvent = Events:WaitForChild("SpawnVisualCoins")

-- ==========================================
-- VARIABLES & ASSETS
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local SFX = SoundService:WaitForChild("SFX")
local CoinTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Currency"):WaitForChild("Coin")

local character, humanoid, rootPart
local jumpConnection = nil
local knockbackConnection = nil
local initialized = false
local CrosshairUI = nil

local state = { 
	isMouseLocked = false, 
	isSpinning = false,
	activeShakePreset = nil
}

local OTS_CONFIG = { OFFSET = Vector3.new(2.75, 0, 0), TRANSITION_SPEED = 10 }
local currentOffset = Vector3.zero 

local camShake, walkShakeInstance, chargeShakeInstance = nil, nil, nil
local baseFOV = 70

local AUTO_AIM_MAX_DIST = 25        
local AUTO_AIM_ANGLE = math.rad(10) 
local AUTO_AIM_SPEED = 6            

local playerOverrideTimer = 0
local currentAimWeight = 0
local lastTouchTime = 0

-- ==========================================
-- UI & CAMERA FUNCTIONS 
-- ==========================================
function GameplayController.SetCrosshair(_state)
end

function GameplayController.TriggerPresetShake(presetName)
	if not camShake then return end

	local isAllowedToFight = (PlayerData.Get(LocalPlayer, "IsOnArena") == true)
		or (PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)
	if not isAllowedToFight then
		if presetName == "Explosion" then presetName = "Bump" else return end
	end

	if CameraShaker.Presets[presetName] then
		camShake:Shake(CameraShaker.Presets[presetName])
	end
end

function GameplayController.StartChargeFeedback()
	if not camShake then return end
	if not chargeShakeInstance then
		local isAllowedToFight = (PlayerData.Get(LocalPlayer, "IsOnArena") == true)
			or (PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)
		local preset = isAllowedToFight and CameraShaker.Presets.Earthquake or CameraShaker.Presets.Vibration
		chargeShakeInstance = camShake:ShakeSustain(preset)
	end
	TweenService:Create(Camera, TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {FieldOfView = 60}):Play()
end

function GameplayController.StopChargeFeedback()
	if chargeShakeInstance then
		chargeShakeInstance:StartFadeOut(0.2)
		chargeShakeInstance = nil
	end
	TweenService:Create(Camera, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {FieldOfView = baseFOV}):Play()
end

-- ==========================================
-- VFX RENDERING
-- ==========================================
local function fadeOutVFX(effect: Instance, duration: number)
	local visuals = {}

	local function collect(instance: Instance)
		if instance:IsA("ParticleEmitter") then
			visuals[instance] = instance.Transparency
			instance.Enabled = false
		elseif instance:IsA("Beam") then
			visuals[instance] = instance.Transparency
		end
	end

	collect(effect)
	for _, descendant in effect:GetDescendants() do
		collect(descendant)
	end

	local elapsed = 0
	while elapsed < duration and effect.Parent do
		elapsed += RunService.Heartbeat:Wait()
		local alpha = math.clamp(elapsed / duration, 0, 1)

		for visual, original in visuals do
			if not visual.Parent then
				continue
			end

			local keypoints = {}
			for _, point in original.Keypoints do
				table.insert(keypoints, NumberSequenceKeypoint.new(
					point.Time,
					point.Value + (1 - point.Value) * alpha,
					point.Envelope * (1 - alpha)
					))
			end

			visual.Transparency = NumberSequence.new(keypoints)
		end
	end

	effect:Destroy()
end
function GameplayController.PlayVFX(effectName, cframe :CFrame)
	local vfxFolder = ReplicatedStorage:WaitForChild("Assets"):FindFirstChild("VFX")
	if not vfxFolder or not cframe then return end

	local effectTemplate = vfxFolder:FindFirstChild(effectName)
	if not effectTemplate then return end

	local clone = effectTemplate:Clone()
	clone.CFrame = cframe

	if clone:IsA("BasePart") then clone.Anchored, clone.CanCollide, clone.CanTouch, clone.CanQuery = true, false, false, false end
	clone.Parent = workspace.Terrain
	
	local maxLifeTime = 0
	for _, child in clone:GetDescendants() do
		if child:IsA("ParticleEmitter") then
			child:Emit(child:GetAttribute("EmitCount") or 10)
			if child.Lifetime.Max > maxLifeTime  then
				maxLifeTime = child.Lifetime.Max
			end
		end
	end
	
	Debris:AddItem(clone,maxLifeTime)
end

function GameplayController.PlayDeathVFX(effectName, cframe :CFrame)
	local vfxFolder = ReplicatedStorage:WaitForChild("Assets"):FindFirstChild("VFX")
	if not vfxFolder or not cframe then return end

	local effectTemplate = vfxFolder:FindFirstChild(effectName)
	if not effectTemplate then return end

	local clone = effectTemplate:Clone()
	clone.CFrame = cframe * CFrame.new(0, -40, 0)
	clone.CFrame = clone.CFrame * CFrame.Angles(0, 0, math.rad(180))
	
	if clone:IsA("BasePart") then clone.Anchored, clone.CanCollide, clone.CanTouch, clone.CanQuery = true, false, false, false end
	clone.Parent = workspace.Terrain

	task.delay(0.25,function()
		fadeOutVFX(clone, 1.5)
	end)
end

local lastVariant = {}

function GameplayController.PlayRandomDeathVFX(prefix, cframe: CFrame)
	local vfxFolder = ReplicatedStorage:WaitForChild("Assets"):FindFirstChild("VFX")
	if not vfxFolder or not cframe then return end

	local variants = {}
	for _, child in vfxFolder:GetChildren() do
		if child.Name:sub(1, #prefix) == prefix then
			table.insert(variants, child.Name)
		end
	end
	if #variants == 0 then return end

	local name
	repeat
		name = variants[math.random(#variants)]
	until name ~= lastVariant[prefix] or #variants == 1
	lastVariant[prefix] = name

	GameplayController.PlayDeathVFX(name, cframe)
end

-- ==========================================
-- INTERNAL LOGIC
-- ==========================================
local function movementBlocked(print: boolean?)
	local blocked = not character or (rootPart and Attributes.Get(rootPart, "KBActive") == true) or character:GetAttribute("TimeStopped") == true
		or character:GetAttribute("IsFrozen") == true or PlayerData.Get(LocalPlayer, "IsFrozen") == true
		or character:GetAttribute("MovementLocked") == true
		or PlayerData.Get(LocalPlayer, "TeleportingActive") == true or (rootPart and rootPart.Anchored)
	
	return blocked
end
local function updateCharacterReferences(newCharacter)
	character = newCharacter
	humanoid = character:WaitForChild("Humanoid", 3)
	rootPart = character:WaitForChild("HumanoidRootPart", 3)
	

	if jumpConnection then jumpConnection:Disconnect() end
	if knockbackConnection then knockbackConnection:Disconnect() end
	knockbackConnection = character:GetAttributeChangedSignal("IsRagdolled"):Connect(function()

		if character:GetAttribute("IsRagdolled") then
			GameplayController.StopChargeFeedback()
			GameplayController.TriggerPresetShake("Bump")
		end
	end)
	if humanoid then
		local shownJump = Attributes.Get(humanoid, "SALastJump")
		jumpConnection = Attributes.Observe(humanoid, "SALastJump", function()
			local current = Attributes.Get(humanoid, "SALastJump")
			if current == shownJump then
				return
			end
			shownJump = current
			if movementBlocked() or not rootPart then
				return
			end
			GameplayController.PlayVFX("JumpEffect", rootPart.CFrame)
			local soundName = if Attributes.Get(humanoid, "SAJumpKind") == "Air" then "DoubleJump" else "Jump"
			local sound = SFX:FindFirstChild(soundName)
			if sound then
				sound:Play()
			end
		end)
	end
end

local function setMouseLockState(locked)
	state.isMouseLocked = locked
	if locked then
		UserInputService.MouseIconEnabled = false 
		if CrosshairUI then CrosshairUI.Visible = true end
	else
		UserInputService.MouseIconEnabled, UserInputService.MouseBehavior = true, Enum.MouseBehavior.Default
		if CrosshairUI then CrosshairUI.Visible = false end
		-- Body rotation belongs to the shared movement simulation.
	end
end

local function checkCombatZones()
	local isAllowedToFight = (PlayerData.Get(LocalPlayer, "IsOnArena") == true)
		or (PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)
	if not isAllowedToFight then
		PlayerData.SetLocal(LocalPlayer, "ShiftLock", false)
	end
end

local function getClosestTargetToCrosshair()
	local bestTarget = nil
	local smallestAngle = AUTO_AIM_ANGLE
	local camCFrame = Camera.CFrame

	local function checkTarget(model)
		if model == character then return end
		local targetRoot = model:FindFirstChild("HumanoidRootPart")
		local targetHum = model:FindFirstChildOfClass("Humanoid")
		if not (targetRoot and targetHum and targetHum.Health > 0) then return end

		local isPlayer = Players:GetPlayerFromCharacter(model)
		if isPlayer and PlayerData.Get(isPlayer, "IsInvulnerable") then
			return
		end

		local dist = (targetRoot.Position - camCFrame.Position).Magnitude
		if dist > AUTO_AIM_MAX_DIST then return end

		local dirToTarget = (targetRoot.Position - camCFrame.Position).Unit
		local angle = math.acos(math.clamp(camCFrame.LookVector:Dot(dirToTarget), -1, 1))

		if angle < smallestAngle then
			smallestAngle = angle
			bestTarget = targetRoot
		end
	end

	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then checkTarget(p.Character) end
	end

	for _, npc in ipairs(CollectionService:GetTagged("ArenaNPC")) do checkTarget(npc) end
	for _, npc in ipairs(CollectionService:GetTagged("LobbyNPC")) do checkTarget(npc) end

	return bestTarget
end

local function handleCameraAndMovement(dt)
	if not (humanoid and rootPart) then return end

	state.isSpinning = character:GetAttribute("IsSpinning") or false
	local isRagdolled = movementBlocked()

	local isAllowedToFight = (PlayerData.Get(LocalPlayer, "IsOnArena") == true)
		or (PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)
	local isCurrentlyLocked = (isAllowedToFight and state.isMouseLocked)

	local targetOffset = (isCurrentlyLocked and not state.isSpinning and not isRagdolled) and OTS_CONFIG.OFFSET or Vector3.zero
	currentOffset = currentOffset:Lerp(targetOffset, math.clamp(dt * OTS_CONFIG.TRANSITION_SPEED, 0, 1))
	humanoid.CameraOffset = currentOffset
	-- ==========================================
	-- AUTO-AIM SYSTEM
	-- ==========================================
	if isAllowedToFight and PlayerData.Get(LocalPlayer, "Setting_AutoAim") and not isRagdolled then
		local mouseDelta = UserInputService:GetMouseDelta()
		if mouseDelta.Magnitude > 1.5 then playerOverrideTimer = 0.35 end

		playerOverrideTimer = math.max(0, playerOverrideTimer - dt)
		currentAimWeight = math.clamp(currentAimWeight + (playerOverrideTimer > 0 and -(dt * 8) or (dt * 3)), 0, 1)

		if currentAimWeight > 0 then
			local targetRoot = getClosestTargetToCrosshair()
			if targetRoot then
				local camPos = Camera.CFrame.Position
				local targetPos = targetRoot.Position
				local horizontalDist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(camPos.X, 0, camPos.Z)).Magnitude
				local aimPosition = Vector3.new(targetPos.X, camPos.Y + (Camera.CFrame.LookVector.Y * horizontalDist), targetPos.Z)
				Camera.CFrame = Camera.CFrame:Lerp(CFrame.lookAt(camPos, aimPosition), dt * AUTO_AIM_SPEED * currentAimWeight)
			end
		end
	else
		currentAimWeight, playerOverrideTimer = 0, 0
	end

	-- ==========================================
	-- SHIFT-LOCK / BODY ROTATION
	-- ==========================================
	if isCurrentlyLocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	end

	-- ==========================================
	-- CAMERA SHAKE
	-- ==========================================
	if walkShakeInstance then
		walkShakeInstance:StartFadeOut(0.5)
		walkShakeInstance = nil
		state.activeShakePreset = nil
	end
end

-- ==========================================
-- VFX: COINS RENDERING
-- ==========================================
local visualCoinFlights = {}
local visualCoinConnection
local visualCoinParts, visualCoinFrames = {}, {}

local function collectVisualCoin(data)
	local coin = data.coin
	data.trail.Enabled = false
	local coinSound = SFX:FindFirstChild("CoinCollect")
	if coinSound then coinSound:Play() end
	TweenService:Create(coin, TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {Size = data.originalSize * 1.5}):Play()
	task.wait(0.08)
	if not coin.Parent then return end
	TweenService:Create(coin, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.In), {Size = Vector3.zero}):Play()
	task.wait(0.12)
	coin:Destroy()
end

local function updateVisualCoins(dt)
	table.clear(visualCoinParts)
	table.clear(visualCoinFrames)
	for i = #visualCoinFlights, 1, -1 do
		local data = visualCoinFlights[i]
		local coin = data.coin
		local character = data.targetPlayer.Character
		local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
		if not coin.Parent or not targetRoot then
			coin:Destroy()
			table.remove(visualCoinFlights, i)
		else
			local direction = targetRoot.Position - coin.Position
			if direction.Magnitude < 3 then
				table.remove(visualCoinFlights, i)
				task.spawn(collectVisualCoin, data) -- Collection tweens must not yield the shared update.
			else
				data.speed += 120 * dt
				table.insert(visualCoinParts, coin)
				table.insert(visualCoinFrames, CFrame.new(coin.Position + direction.Unit * data.speed * dt)
					* coin.CFrame.Rotation * CFrame.Angles(data.spinX * dt, data.spinY * dt, data.spinZ * dt))
			end
		end
	end
	if #visualCoinParts > 0 then workspace:BulkMoveTo(visualCoinParts, visualCoinFrames, Enum.BulkMoveMode.FireCFrameChanged) end
	if #visualCoinFlights == 0 and visualCoinConnection then
		visualCoinConnection:Disconnect()
		visualCoinConnection = nil
	end
end

local function renderVisualCoins(startPos, targetPlayer, amount: number?, flyHeight: NumberRange?)
	if not targetPlayer or not targetPlayer.Character then return end

	local deathSound = SFX:FindFirstChild("Death")
	if deathSound then deathSound:Play() end

	for _ = 1, amount or 5 do
		task.spawn(function()
			local coin = CoinTemplate:Clone()
			coin.Anchored, coin.CanCollide, coin.CFrame = true, false, CFrame.new(startPos)
			coin.CanTouch, coin.CanQuery = false, false
			local originalSize = coin.Size

			local att0 = Instance.new("Attachment", coin) att0.Position = Vector3.new(0, coin.Size.Y / 2, 0)
			local att1 = Instance.new("Attachment", coin) att1.Position = Vector3.new(0, -coin.Size.Y / 2, 0)

			local trail = Instance.new("Trail", coin)
			trail.Attachment0, trail.Attachment1 = att0, att1
			trail.Color = ColorSequence.new(Color3.new(1, 1, 1))
			trail.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)})
			trail.Lifetime = 0.3
			coin.Parent = workspace.Terrain
	
			local randomHeight = if flyHeight then math.random(flyHeight.Min+0.1, flyHeight.Max+0.1) else 92 + (math.random()*4 - 2)

			local burstTarget = startPos + Vector3.new(math.random(-8, 8), randomHeight, math.random(-8, 8))
			local randomAngles = CFrame.Angles(math.rad(math.random(-15, 15)), math.rad(math.random(0, 360)), math.rad(math.random(-15, 15)))
			
			local burstTween = TweenService:Create(coin, TweenInfo.new(0.4, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {
				CFrame = CFrame.new(burstTarget) * randomAngles
			})
			burstTween:Play()
			burstTween.Completed:Wait()

			local spinX, spinZ = math.random(-50, 50) * 0.01, math.random(-50, 50) * 0.01 
			local spinY = math.random(12, 22) * (math.random() > 0.5 and 1 or -1) 
			table.insert(visualCoinFlights, {
				coin = coin, targetPlayer = targetPlayer, trail = trail, originalSize = originalSize,
				speed = 0, spinX = spinX, spinY = spinY, spinZ = spinZ,
			})
			if not visualCoinConnection then visualCoinConnection = RunService.Heartbeat:Connect(updateVisualCoins) end
			Debris:AddItem(coin, 5)
		end)
	end
end

-- ==========================================
-- INIT
-- ==========================================
function GameplayController.Init()
	if initialized then return end
	initialized = true
	-- Stop confirms the outcome even if character attributes arrive later.
	if LocalPlayer.Character then
		task.spawn(updateCharacterReferences, LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(updateCharacterReferences)

	local HUD = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MainGui"):WaitForChild("HUD")
	CrosshairUI = HUD:WaitForChild("Crosshair")
	baseFOV = Camera.FieldOfView

	camShake = CameraShaker.new(Enum.RenderPriority.Camera.Value + 1, function(shakeCFrame) Camera.CFrame = Camera.CFrame * shakeCFrame end)
	camShake:Start()

	PlayerData.Observe(LocalPlayer, "IsOnArena", checkCombatZones)
	PlayerData.Observe(LocalPlayer, "IsInTrainingArea", checkCombatZones)

	PlayerData.Observe(LocalPlayer, "ShiftLock", function()
		local locked = PlayerData.Get(LocalPlayer, "ShiftLock") or false
		local isAllowedToFight = (PlayerData.Get(LocalPlayer, "IsOnArena") == true)
			or (PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)
		if locked and not isAllowedToFight then
			PlayerData.SetLocal(LocalPlayer, "ShiftLock", false)
			return
		end
		setMouseLockState(locked)
	end)

	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		local isAllowedToFight = (PlayerData.Get(LocalPlayer, "IsOnArena") == true)
			or (PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)
		if not isAllowedToFight then return end

		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			PlayerData.SetLocal(LocalPlayer, "ShiftLock", not state.isMouseLocked)
		elseif input.UserInputType == Enum.UserInputType.Touch then
			local now = os.clock()
			if now - lastTouchTime < 0.3 then
				local ray = Camera:ViewportPointToRay(input.Position.X, input.Position.Y)
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Include
				params.FilterDescendantsInstances = {character}

				if workspace:Raycast(ray.Origin, ray.Direction * 100, params) then
					PlayerData.SetLocal(LocalPlayer, "ShiftLock", not state.isMouseLocked)
					lastTouchTime = 0
					return
				end
			end
			lastTouchTime = now
		end
	end)

	-- ==========================================
	-- JUMP LOGIC
	-- ==========================================
	SpawnVisualCoinsEvent.OnClientEvent:Connect(renderVisualCoins)
	RunService:BindToRenderStep("CameraUpdate", Enum.RenderPriority.Camera.Value + 1, handleCameraAndMovement)
end

return GameplayController
