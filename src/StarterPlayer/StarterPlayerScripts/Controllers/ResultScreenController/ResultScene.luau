--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--// Modules
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)

--// References
local Camera = workspace.Camera
local EndingModel = workspace:WaitForChild("Ending")
local CharacterFolder = EndingModel:WaitForChild("Character")
local CharacterLocation = CharacterFolder.CharLocation
local RunAnimation = CharacterFolder.RunAnim
local IdleAnimation = CharacterFolder.IdleAnim
local WeaponAnimation = CharacterFolder.WeaponHold
local LocalPlayer = Players.LocalPlayer :: Player
local Assets = ReplicatedStorage.Assets
local WeaponsFolder = Assets.Weapons
local SFXFolder = SoundService.SFX
local PlayerGui  = LocalPlayer.PlayerGui
local ResultScreenUI = PlayerGui:WaitForChild("ResultScreen")
local ResultFrame = ResultScreenUI:WaitForChild("ResultFrame")
local Cinematic = ResultFrame.Cinematic

--// Constants
local EQUIPPED_WEAPON_ATTRIBUTE = "EquippedWeaponName"
local CAMERA_NOISE_SPEED = 0.15
local CAMERA_NOISE_FACTOR = math.rad(10)
local CHINEMA_ROTATION_FACTOR = 5
local PARALLAX_VERTICAL = 1
local PARALLAX_HORIZONTAL = 1
local PARALLAX_UI_FACTOR = 0.01
local SUMMARY_TRANSITION_TIME = 0.5

--// Types
export type ResultScene = {
	CameraEnabled: boolean,
	CameraThread: thread?,
    SummaryStart: number,
	Setup: (self: ResultScene) -> (),
	Start: (self: ResultScene) -> (),
    LoadCharacter: (self: ResultScene) -> (),
	SetSceneCameraEnabled: (self: ResultScene, enabled: boolean) -> (),
    SwitchToSummary: (self: ResultScene) -> (),
}

local function ApplyParallaxToUIs(parallaxUI: Vector2)    
    ResultFrame.Position = UDim2.fromScale(0.5, 0.5) + UDim2.fromScale(parallaxUI.X, parallaxUI.Y)
    ResultFrame.Holder.Showcase.MatchScore.Position = UDim2.fromScale(0.75, 0.05) + UDim2.fromScale(parallaxUI.X, parallaxUI.Y)
end

local ResultScene = {} :: ResultScene

function ResultScene:Setup()
	self.CameraEnabled = false
    self.SummaryStart = 0
end

function ResultScene:Start()
    task.spawn(function()
        local existingChar = CharacterFolder:WaitForChild("Character")
        local char = Players:CreateHumanoidModelFromUserIdAsync(LocalPlayer.User) :: typeof(existingChar)
        char.Name = "Character"

        local humanoid = char:WaitForChild("Humanoid")
        humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

        local root = char:WaitForChild("HumanoidRootPart")
        root.Anchored = true

        char:PivotTo(CharacterLocation.CFrame)
        char.Parent = CharacterFolder
        existingChar:Destroy()
    end)
end

function ResultScene:SetSceneCameraEnabled(enabled)
	if self.CameraThread then
		task.cancel(self.CameraThread) 
	end

    Camera.CameraType = enabled and Enum.CameraType.Scriptable or Enum.CameraType.Custom
    
    if enabled then
        self.SummaryStart = 0
        self.CameraThread = task.spawn(function()
            local firstRender = false
            local s = time()
            local animTime = 2
            local animDistance = 30

            local animLeftAwait = 2
            local animLeftTime = 0.5
            local animLeftDistance = 3.5

            local charAnimTime = 3
            local characterAnimDistance = 40

            local cinematicAwait = 0
            local cinematicTime = 3

            Cinematic.Visible = true

            local char = CharacterFolder:WaitForChild("Character")
            local hum = char:WaitForChild("Humanoid")
            local animator = hum:WaitForChild("Animator")

            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                track:Stop()
            end

            local playerStopped = false
            local runningTrack = animator:LoadAnimation(RunAnimation)

            runningTrack.Priority = Enum.AnimationPriority.Movement
            runningTrack:Play()

            local idleTrack = animator:LoadAnimation(IdleAnimation)
            idleTrack.Priority = Enum.AnimationPriority.Idle
            idleTrack:Play()

            local weaponAnimation = WeaponAnimation
            local playerCurrentEquippedWeapon = tostring(LocalPlayer:GetAttribute(EQUIPPED_WEAPON_ATTRIBUTE))

            local weaponData = WeaponConfig.GetWeaponInfo(playerCurrentEquippedWeapon)

            if weaponData then
                local animId = weaponData.Idle

                local anim = Instance.new("Animation")
                anim.AnimationId = animId

                weaponAnimation = anim
            end

            local existingWeapon = char:FindFirstChild("Weapon")

            if existingWeapon then
                existingWeapon:Destroy()
            end

	        local hand = char:FindFirstChild("RightHand")            
            local weaponTemplate = WeaponsFolder:FindFirstChild(playerCurrentEquippedWeapon) :: Model?
            
            if hand and weaponTemplate then
                local weaponModel = weaponTemplate:Clone()
                weaponModel.Name = "Weapon"
	            weaponModel:PivotTo(hand.CFrame)
                
	            local weaponMainPart = weaponModel:FindFirstChild("Main", true) :: BasePart
                if weaponMainPart then
                    local weld = Instance.new("WeldConstraint")
                    weld.Part0 = hand
                    weld.Part1 = weaponMainPart
                    weld.Parent = weaponMainPart
                end

                weaponModel.Parent = char
            end

            local weaponTrack = animator:LoadAnimation(weaponAnimation)
            weaponTrack.Priority = Enum.AnimationPriority.Action
            weaponTrack:Play()

            SoundService:PlayLocalSound(SFXFolder.Wind)

            local currentParallax = Vector2.zero

            while true do
                local dt = task.wait()
                local elapsed = time() - s
				local t = time() * CAMERA_NOISE_SPEED
                local progress = 1 - TweenService:GetValue(
                    math.clamp(elapsed / animTime, 0, 1),
                    Enum.EasingStyle.Exponential, Enum.EasingDirection.InOut
                )

                local distance = animDistance * progress

                local leftProgress = TweenService:GetValue(
                    math.clamp((elapsed - animLeftAwait) / animLeftTime, 0, 1),
                    Enum.EasingStyle.Quart, Enum.EasingDirection.InOut
                )

                local leftDistance = animLeftDistance * leftProgress
                				
				local rndX = math.noise(t, 0, 0) * CAMERA_NOISE_FACTOR
				local rndY = math.noise(0, t, 0) * CAMERA_NOISE_FACTOR
				local rndZ = math.noise(0, 0, t) * CAMERA_NOISE_FACTOR			
				local angleNoise = CFrame.Angles(rndX, rndY, rndZ)

				local screenSize = Camera.ViewportSize
				local mouseLocation = UserInputService:GetMouseLocation()				
				local screenRatio = screenSize.X / screenSize.Y
				local relatedLocation = mouseLocation / screenSize - Vector2.new(0.5, 0.5)
				
                local parallaxX = relatedLocation.X * PARALLAX_HORIZONTAL
				local parallaxY = -relatedLocation.Y / screenRatio * PARALLAX_VERTICAL
                
				local targetParallax = Vector2.new(parallaxX, parallaxY)
				currentParallax = currentParallax:Lerp(targetParallax, dt / 0.15)
				local parallaxCFrame = CFrame.new(currentParallax.X, currentParallax.Y, 0)

                local showcaseCFrame = CFrame.new(leftDistance, -0.5, 7.5 + distance)
                local summaryCFrame = CFrame.new(-2, 1, 3.5)

                local sceneProgress = 0

                if self.SummaryStart ~= 0 then
                    local summaryElapsed = time() - self.SummaryStart
                    local alpha = summaryElapsed / SUMMARY_TRANSITION_TIME
                    sceneProgress = TweenService:GetValue(alpha, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
                end

                local sceneCFrame = showcaseCFrame:Lerp(summaryCFrame, sceneProgress)
				
                local targetCFrame = CharacterLocation.CFrame 
                    * CFrame.Angles(0, math.rad(180), 0) 
                    * angleNoise
                    * sceneCFrame
                    * CFrame.Angles(math.rad(5 + (progress * -25)), 0, 0)
                    * parallaxCFrame

                local intensity = math.clamp((elapsed - 1), 0, 1)
                local parallaxUI = targetParallax * PARALLAX_UI_FACTOR * Vector2.new(1, -1) * intensity
                ApplyParallaxToUIs(parallaxUI)

                if not firstRender then
                    firstRender = true
                    Camera.CFrame = targetCFrame
                else
                    Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, dt / 0.25)
                end

                local charProgress = 1 - TweenService:GetValue(
                    math.clamp(elapsed / charAnimTime, 0, 1),
                    Enum.EasingStyle.Sine, Enum.EasingDirection.Out
                )

                if elapsed >= charAnimTime and not playerStopped then
                    playerStopped = true
                    runningTrack:Stop()
                elseif elapsed < charAnimTime then
                    runningTrack:AdjustSpeed(charProgress ^ 0.1)
                end

                local characterDistance =  characterAnimDistance * charProgress
                local characterCFrame = CharacterLocation.CFrame * 
                    CFrame.new(0, 0, characterDistance)

                char:PivotTo(characterCFrame)

                local cinematicProgress = TweenService:GetValue(
                    math.clamp((elapsed - cinematicAwait) / cinematicTime, 0, 1),
                    Enum.EasingStyle.Quart, Enum.EasingDirection.InOut
                )

                local cinematicRotation = rndZ / CAMERA_NOISE_FACTOR * CHINEMA_ROTATION_FACTOR

                Cinematic.Rotation = cinematicRotation
                Cinematic.Top.Size = UDim2.fromScale(1.5, cinematicProgress * 0.25)
                Cinematic.Bottom.Size = UDim2.fromScale(1.5, cinematicProgress * 0.25)
            end
        end)
    end
end

function ResultScene:SwitchToSummary()
    self.SummaryStart = time()
end

return ResultScene