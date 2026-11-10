--!strict
-- Celebrates purchases and incoming gifts with queued titles, fireworks, and pooled particles.

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

-- References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local ShopEffectFrame = PlayerGui:WaitForChild("MainGui"):WaitForChild("ShopEffectFrame") :: Frame
local Title = ShopEffectFrame:WaitForChild("Title") :: Frame
local DescriptionText = Title:WaitForChild("Description") :: TextLabel
local TitleScale = Title:WaitForChild("UIScale") :: UIScale
local Particles = ShopEffectFrame:WaitForChild("Particles") :: Frame
local Template = Particles:WaitForChild("Template") :: Frame & {UIShadow: UIShadow}
local TemplateBig = Particles:WaitForChild("Template_Big") :: Frame & {UIScale: UIScale}
local FireworkInitial = SoundService.SFX.FireworkInitial
local FireworkExplosion = SoundService.SFX.FireworkExplosion
local SuccessSound = SoundService.SFX.Success

-- Constants
local PARTICLE_LIFETIME = 5
local MOVEMENT_TIME = 1.5
local TRANSPARENT_AWAIT = 0.75
local TRANSPARENT_TIME = 1
local BIG_MOVE_TIME = 0.45
local BIG_SHRINK_TIME = 0.25
local BIG_OFFSCREEN_DISTANCE = 0.2
local MIN_HORIZONTAL_BOUND = -1.5
local MAX_HORIZONTAL_BOUND = 2
local MIN_VERTICAL_BOUND = -0.25
local MIN_MOVE_SPEED = 1
local MAX_MOVE_SPEED = 2
local MIN_ROTATION_SPEED = 360 * 20
local MAX_ROTATION_SPEED = 360 * 30
local PARTICLE_COUNT = 20
local FIRE_COUNT = 10

-- Properties
local RandomGenerator = Random.new()
local UpdateConnection: RBXScriptConnection? = nil
local Cached: {ParticleFrame} = {}
local EffectShowThread: thread?
local PendingEffects: {EffectMessage} = {}
local DefaultText: {[TextLabel]: string} = {}
for _, descendant in Title:GetDescendants() do
    if descendant:IsA("TextLabel") then
        DefaultText[descendant] = descendant.Text
    end
end

-- Types
type EffectMessage = {
    Title: string?,
    Description: string?,
}

type ParticleData = {
	MoveSpeed: number,
	RotationSpeed: number,
	Position: Vector2,
	Direction: Vector2,
	Elapsed: number,
}

type ParticleFrame = typeof(Template)

export type ShopEffectController = {
    Items: {[ParticleFrame]: ParticleData},
	Init: () -> (),
	Setup: (self: ShopEffectController) -> (),
	Start: (self: ShopEffectController) -> (),
	FireParticle: (self: ShopEffectController, count: number) -> (),
    ShowEffect: (self: ShopEffectController, message: string?, description: string?) -> (),
}

-- Module/controller table
local Controller: ShopEffectController = {
	Items = {},
} :: ShopEffectController

-- APIs
local function GetParticle(): ParticleFrame
    return table.remove(Cached) or Template:Clone()
end

local function DestroyParticle(item: ParticleFrame)
	Controller.Items[item] = nil
	item.Parent = nil :: any
    table.insert(Cached, item)
end

function Controller:Setup()
	Template.Visible = false
	TemplateBig.Visible = false
end

function Controller:Start()
	if UpdateConnection then
		return
	end

	UpdateConnection = RunService.RenderStepped:Connect(function(dt: number)
		for item, data in Controller.Items do
			if not item.Parent then
				Controller.Items[item] = nil
				continue
			end

            item.Visible = true
			data.Elapsed += dt
            local speedMultiplier = 1 - TweenService:GetValue(math.clamp(data.Elapsed / MOVEMENT_TIME, 0, 1), Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
            local transparency = math.clamp((data.Elapsed - TRANSPARENT_AWAIT) / TRANSPARENT_TIME, 0, 1)

			data.Position += data.Direction * data.MoveSpeed * dt * speedMultiplier
			item.Position = UDim2.fromScale(data.Position.X, data.Position.Y)
			item.Rotation += data.RotationSpeed * dt * speedMultiplier
            item.BackgroundTransparency = transparency
            item.UIShadow.Transparency = 0.75 + transparency * 0.25

			if data.Elapsed >= PARTICLE_LIFETIME
				or data.Position.Y < MIN_VERTICAL_BOUND
				or data.Position.X < MIN_HORIZONTAL_BOUND
				or data.Position.X > MAX_HORIZONTAL_BOUND
			then
				DestroyParticle(item)
			end
		end
	end)

    UserInputService.InputBegan:Connect(function(input)
        if RunService:IsStudio() and input.KeyCode == Enum.KeyCode.Y and UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) then
            self:ShowEffect()
        end
    end)

    for i = 1, 50 do
        table.insert(Cached, Template:Clone())
    end
end

local function FireParticleBurst(count: number, position: Vector2)
    local totalCount = math.floor(count)
    local anglePerItem = math.pi * 2 / totalCount

	for i = 1, totalCount do
		local angle = anglePerItem * i * RandomGenerator:NextNumber(0.9, 1.1)
		local direction = Vector2.new(math.cos(angle), math.sin(angle))
		local item = GetParticle()
        local color = Color3.fromHSV(RandomGenerator:NextNumber(), 1, 1)

		item.Visible = false
		item.Position = UDim2.fromScale(-1, -1)
		item.BackgroundTransparency = 0
        item.BackgroundColor3 = color
		item.UIShadow.Transparency = 0.75
        item.UIShadow.Color = color
		item.Parent = Particles

        local rotateDirection = math.sign(direction.X)
        if rotateDirection == 0 then
            rotateDirection = 1
        end

		Controller.Items[item] = {
			MoveSpeed = RandomGenerator:NextNumber(MIN_MOVE_SPEED, MAX_MOVE_SPEED),
			RotationSpeed = RandomGenerator:NextNumber(MIN_ROTATION_SPEED, MAX_ROTATION_SPEED)
				* rotateDirection,
			Position = position,
			Direction = direction,
			Elapsed = 0,
		}
	end
end

function Controller:FireParticle(count: number)
	local totalCount = math.floor(count)
	if totalCount <= 0 then
		return
	end

    local posX = math.lerp(-0.25, 1.25, RandomGenerator:NextNumber())

    local position = Vector2.new(posX, RandomGenerator:NextNumber())
    local bigItem = TemplateBig:Clone()
    local scaleInstance = bigItem.UIScale

    local startY = if position.Y <= 0.5 then -BIG_OFFSCREEN_DISTANCE else 1 + BIG_OFFSCREEN_DISTANCE
    local uiScale = scaleInstance :: UIScale
    bigItem.Visible = true
    bigItem.Position = UDim2.fromScale(position.X, startY)
    bigItem.Parent = Particles
    SoundService:PlayLocalSound(FireworkInitial)

    TweenUtils.PlayTweenSequence({
        true,
        TweenService:Create(
            bigItem,
            TweenInfo.new(BIG_MOVE_TIME + BIG_SHRINK_TIME, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
            {Rotation = 360 * 5 * math.lerp(1, 1.15, math.random())}
        ),
        TweenService:Create(
            bigItem,
            TweenInfo.new(BIG_MOVE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            {Position = UDim2.fromScale(position.X, position.Y)}
        ),
        TweenService:Create(
            uiScale,
            TweenInfo.new(BIG_SHRINK_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.In),
            {Scale = 0}
        ),
        function()
            bigItem:Destroy()
            SoundService:PlayLocalSound(FireworkExplosion)
            FireParticleBurst(totalCount, position)
        end
    })
end

local function SetMessage(message: EffectMessage)
    for label, default in DefaultText do
        local text = if label == DescriptionText or label:IsDescendantOf(DescriptionText)
            then message.Description else message.Title
        if text == nil then
            label.Text = default
        else
            if label.RichText then
                text = string.gsub(text, "&", "&amp;")
                text = string.gsub(text, "<", "&lt;")
                text = string.gsub(text, ">", "&gt;")
            end
            label.Text = text
        end
    end
end

function Controller:ShowEffect(message, description)
    table.insert(PendingEffects, {Title = message, Description = description})
    if EffectShowThread then
        return
    end

    EffectShowThread = task.spawn(function()
        while #PendingEffects > 0 do
            SetMessage(table.remove(PendingEffects, 1) or {})
            ShopEffectFrame.Visible = true
            TweenUtils.PlayTweenSequence({
                TweenService:Create(TitleScale, TweenInfo.new(0), {Scale = 0}),
                TweenService:Create(TitleScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1})
            })

            SoundService:PlayLocalSound(SuccessSound)

            for i = 1, FIRE_COUNT do
                self:FireParticle(PARTICLE_COUNT)
                task.wait(0.25 + 0.5 * math.random())
            end

            task.wait(2)
            TweenUtils.PlayTweenSequence({
                TweenService:Create(TitleScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.In), {Scale = 0}),
            }, true)

            ShopEffectFrame.Visible = false
        end
        SetMessage({})
        EffectShowThread = nil
    end)
end

function Controller.Init()
	Controller:Setup()
	Controller:Start()
end

return Controller
