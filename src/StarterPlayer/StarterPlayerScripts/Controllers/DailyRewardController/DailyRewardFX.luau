--!strict
-- DailyRewardFX (CLIENT)
-- All the juice for the daily reward window: ambient card glow/spin, shine sweep, button feel,
-- timer tick, claim burst (confetti + ring + flash + shake), window intro and HUD attention wiggle.
-- Pure visuals: never touches game state, safe to remove.

--// Services
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// Constants
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 214, 79)
local SPIN_INFO = TweenInfo.new(16, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1)
local WOBBLE_INFO = TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BOB_INFO = TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local GLOW_INFO = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BUTTON_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TICK_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

--// Types
export type AmbientMode = "Claim" | "Next" | "None"

type CardState = {
	Alive: boolean,
	Mode: AmbientMode,
	Tweens: { Tween },
	IconPosition: UDim2?,
	IconRotation: number?,
	GlowTransparency: number?,
	GlowSize: UDim2?,
	SunburstRotation: number?,
}

type WindowState = {
	Tweens: { Tween },
	Token: number,
	HeaderPosition: UDim2?,
	GradientOffset: Vector2?,
	ExitHooked: boolean,
}

type AttentionState = { Token: number, Tween: Tween? }

--// Properties
local CardStates: { [Instance]: CardState } = setmetatable({}, { __mode = "k" }) :: any
local ButtonHooks: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local WindowStates: { [Instance]: WindowState } = setmetatable({}, { __mode = "k" }) :: any
local AttentionStates: { [Instance]: { AttentionState } } = setmetatable({}, { __mode = "k" }) :: any
local Rng = Random.new()

local FX = {}

--// Helpers
local function track(list: { Tween }, tween: Tween): Tween
	table.insert(list, tween)
	tween:Play()
	return tween
end

local function cancelAll(list: { Tween })
	for _, tween in list do
		tween:Cancel()
	end
	table.clear(list)
end

local function getUIScale(parent: Instance): UIScale
	local scale = parent:FindFirstChildOfClass("UIScale")
	if not scale then
		local created = Instance.new("UIScale")
		created.Parent = parent
		scale = created
	end
	return scale :: UIScale
end

local function ensureShine(button: GuiObject): Frame
	local existing = button:FindFirstChild("Shine")
	if existing and existing:IsA("Frame") then
		return existing
	end

	button.ClipsDescendants = true
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Active = false
	shine.BorderSizePixel = 0
	shine.BackgroundColor3 = WHITE
	shine.BackgroundTransparency = 0.35
	shine.AnchorPoint = Vector2.new(0.5, 0.5)
	shine.Size = UDim2.fromScale(0.22, 2)
	shine.Position = UDim2.fromScale(-0.4, 0.5)
	shine.Rotation = 20
	shine.ZIndex = button.ZIndex + 3
	shine.Visible = false

	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = shine
	shine.Parent = button
	return shine
end

local function runShine(button: GuiObject, state: CardState)
	local shine = ensureShine(button)
	task.spawn(function()
		while state.Alive and state.Mode == "Claim" and shine.Parent do
			shine.Visible = true
			shine.Position = UDim2.fromScale(-0.4, 0.5)
			local sweep = TweenService:Create(
				shine,
				TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
				{ Position = UDim2.fromScale(1.4, 0.5) }
			)
			sweep:Play()
			sweep.Completed:Wait()
			shine.Visible = false
			task.wait(1.3)
		end
		shine.Visible = false
	end)
end

local function resetCard(frame: Frame, state: CardState)
	state.Alive = false
	cancelAll(state.Tweens)

	local icon = frame:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		if state.IconPosition then
			icon.Position = state.IconPosition
		end
		icon.Rotation = state.IconRotation or 0
	end

	local glow = frame:FindFirstChild("ImageLabel")
	if glow and glow:IsA("ImageLabel") then
		if state.GlowTransparency then
			glow.ImageTransparency = state.GlowTransparency
		end
		if state.GlowSize then
			glow.Size = state.GlowSize
		end
	end

	local canvas = frame:FindFirstChild("CanvasGroup")
	local sunburst = canvas and canvas:FindFirstChild("Sunburst")
	if sunburst and sunburst:IsA("ImageLabel") then
		sunburst.Rotation = state.SunburstRotation or 0
	end

	local claim = frame:FindFirstChild("Claim")
	local shine = claim and claim:FindFirstChild("Shine")
	if shine and shine:IsA("GuiObject") then
		shine.Visible = false
	end
end

--// APIs
-- Ambient life on a reward card. "Claim" = ready (glow pulse, spinning rays, icon wobble, shine sweep),
-- "Next" = waiting (slow rays + gentle bob), "None" = idle.
function FX.SetCardAmbient(frame: Frame, mode: AmbientMode)
	local state = CardStates[frame]
	if not state then
		local icon = frame:FindFirstChild("Icon")
		local glow = frame:FindFirstChild("ImageLabel")
		local canvas = frame:FindFirstChild("CanvasGroup")
		local sunburst = canvas and canvas:FindFirstChild("Sunburst")
		state = {
			Alive = false,
			Mode = "None",
			Tweens = {},
			IconPosition = if icon and icon:IsA("ImageLabel") then icon.Position else nil,
			IconRotation = if icon and icon:IsA("ImageLabel") then icon.Rotation else nil,
			GlowTransparency = if glow and glow:IsA("ImageLabel") then glow.ImageTransparency else nil,
			GlowSize = if glow and glow:IsA("ImageLabel") then glow.Size else nil,
			SunburstRotation = if sunburst and sunburst:IsA("ImageLabel") then sunburst.Rotation else nil,
		}
		CardStates[frame] = state
	end
	local card = state :: CardState

	if card.Mode == mode and card.Alive == (mode ~= "None") then
		return
	end
	resetCard(frame, card)
	card.Mode = mode
	if mode == "None" then
		return
	end
	card.Alive = true

	local canvas = frame:FindFirstChild("CanvasGroup")
	local sunburst = canvas and canvas:FindFirstChild("Sunburst")
	if sunburst and sunburst:IsA("ImageLabel") then
		local base = card.SunburstRotation or 0
		local info = if mode == "Claim" then SPIN_INFO else TweenInfo.new(36, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1)
		track(card.Tweens, TweenService:Create(sunburst, info, { Rotation = base + 360 }))
	end

	local icon = frame:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		local basePos = card.IconPosition or icon.Position
		track(card.Tweens, TweenService:Create(icon, BOB_INFO, {
			Position = basePos - UDim2.fromScale(0, if mode == "Claim" then 0.03 else 0.015),
		}))
		if mode == "Claim" then
			icon.Rotation = -6
			track(card.Tweens, TweenService:Create(icon, WOBBLE_INFO, { Rotation = 6 }))
		end
	end

	if mode == "Claim" then
		local glow = frame:FindFirstChild("ImageLabel")
		if glow and glow:IsA("ImageLabel") then
			local baseSize = card.GlowSize or glow.Size
			local baseIT = card.GlowTransparency or 0
			glow.ImageTransparency = math.clamp(baseIT + 0.35, 0, 1)
			track(card.Tweens, TweenService:Create(glow, GLOW_INFO, {
				ImageTransparency = baseIT,
				Size = UDim2.new(baseSize.X.Scale * 1.07, baseSize.X.Offset, baseSize.Y.Scale * 1.07, baseSize.Y.Offset),
			}))
		end

		local claim = frame:FindFirstChild("Claim")
		if claim and claim:IsA("GuiObject") then
			runShine(claim, card)
		end
	end
end

-- Hover / press feel for buttons. Skips the visual response while the button is disabled (Active = false).
function FX.AttachButtonFeel(button: GuiButton, hoverScale: number?)
	if ButtonHooks[button] then
		return
	end
	ButtonHooks[button] = true

	local hover = hoverScale or 1.08
	local scale = getUIScale(button)
	local hovering = false
	local current: Tween? = nil

	local function go(target: number, info: TweenInfo)
		if current then
			current:Cancel()
		end
		current = TweenService:Create(scale, info, { Scale = target })
		;(current :: Tween):Play()
	end

	button.MouseEnter:Connect(function()
		hovering = true
		if button.Active then
			go(hover, BUTTON_INFO)
		end
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		go(1, BUTTON_INFO)
	end)
	button.MouseButton1Down:Connect(function()
		if button.Active then
			go(0.9, PRESS_INFO)
		end
	end)
	button.MouseButton1Up:Connect(function()
		go(if hovering and button.Active then hover else 1, BUTTON_INFO)
	end)
end

-- Little bounce on the countdown every time its text changes.
function FX.TimerTick(label: TextLabel)
	local scale = getUIScale(label)
	TweenUtils.PlayTweenSequence({		
		TweenService:Create(scale, TweenInfo.new(0), { Scale = 1.16 }),
		TweenService:Create(scale, TICK_INFO, { Scale = 1 })
	})
end

-- Confetti + shockwave ring + flash around a card. Parented to the window so it clips with it.
function FX.Burst(window: GuiObject, card: GuiObject, color: Color3)
	local windowPos, windowSize = window.AbsolutePosition, window.AbsoluteSize
	if windowSize.X <= 0 or windowSize.Y <= 0 then
		return
	end

	local center = card.AbsolutePosition + card.AbsoluteSize / 2
	local cx = (center.X - windowPos.X) / windowSize.X
	local cy = (center.Y - windowPos.Y) / windowSize.Y
	local baseZ = 60

	local layer = Instance.new("Folder")
	layer.Name = "ClaimFX"
	layer.Parent = window
	Debris:AddItem(layer, 1.6)

	-- flash
	local flash = Instance.new("Frame")
	flash.Active = false
	flash.BorderSizePixel = 0
	flash.BackgroundColor3 = WHITE
	flash.BackgroundTransparency = 0.15
	flash.AnchorPoint = Vector2.new(0.5, 0.5)
	flash.Position = UDim2.fromScale(cx, cy)
	flash.Size = UDim2.fromOffset(card.AbsoluteSize.X, card.AbsoluteSize.Y)
	flash.ZIndex = baseZ
	local flashCorner = Instance.new("UICorner")
	flashCorner.CornerRadius = UDim.new(0, 12)
	flashCorner.Parent = flash
	flash.Parent = layer
	TweenService:Create(flash, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(card.AbsoluteSize.X * 1.25, card.AbsoluteSize.Y * 1.25),
	}):Play()

	-- shockwave rings
	for index = 1, 2 do
		local ring = Instance.new("Frame")
		ring.Active = false
		ring.BackgroundTransparency = 1
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.fromScale(cx, cy)
		ring.Size = UDim2.fromOffset(20, 20)
		ring.ZIndex = baseZ + 1
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = ring
		local stroke = Instance.new("UIStroke")
		stroke.Color = if index == 1 then WHITE else color
		stroke.Thickness = 7
		stroke.Parent = ring
		ring.Parent = layer

		local reach = windowSize.X * (0.16 + 0.07 * index)
		local info = TweenInfo.new(0.5 + 0.1 * index, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.05 * index)
		TweenService:Create(ring, info, { Size = UDim2.fromOffset(reach, reach) }):Play()
		TweenService:Create(stroke, info, { Transparency = 1, Thickness = 1 }):Play()
	end

	-- confetti
	local palette = { color, color:Lerp(WHITE, 0.5), WHITE, GOLD }
	for _ = 1, 26 do
		local piece = Instance.new("Frame")
		piece.Active = false
		piece.BorderSizePixel = 0
		piece.BackgroundColor3 = palette[Rng:NextInteger(1, #palette)]
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = UDim2.fromScale(cx, cy)
		local w = Rng:NextInteger(6, 13)
		piece.Size = UDim2.fromOffset(w, if Rng:NextNumber() > 0.5 then w else math.max(4, w // 2))
		piece.Rotation = Rng:NextInteger(0, 360)
		piece.ZIndex = baseZ + 2
		if Rng:NextNumber() > 0.6 then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = piece
		end
		piece.Parent = layer

		local angle = Rng:NextNumber() * math.pi * 2
		local dist = 0.05 + Rng:NextNumber() * 0.17
		local dx = math.cos(angle) * dist
		local dy = math.sin(angle) * dist * 1.4
		local peakTime = 0.28 + Rng:NextNumber() * 0.16
		local fallTime = 0.5 + Rng:NextNumber() * 0.25

		local rise = TweenService:Create(piece, TweenInfo.new(peakTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(cx + dx, cy + dy - 0.06),
			Rotation = piece.Rotation + Rng:NextInteger(-200, 200),
		})
		local fall = TweenService:Create(piece, TweenInfo.new(fallTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.fromScale(cx + dx * 1.3, cy + dy + 0.22),
			BackgroundTransparency = 1,
			Rotation = piece.Rotation + Rng:NextInteger(-420, 420),
		})
		rise.Completed:Once(function()
			if piece.Parent then
				fall:Play()
			end
		end)
		rise:Play()
	end

	-- window shake
	task.spawn(function()
		local base = window.Rotation
		for _, offset in { -1.6, 1.4, -0.9, 0.5, 0 } do
			local step = TweenService:Create(window, TweenInfo.new(0.05, Enum.EasingStyle.Sine), { Rotation = base + offset })
			step:Play()
			step.Completed:Wait()
		end
		window.Rotation = base
	end)
end

-- Window intro: header drops in with a bounce, title shimmer + header icon wobble start. CloseWindow stops them.
function FX.OpenWindow(window: GuiObject)
	local state = WindowStates[window]
	if not state then
		local newState: WindowState = { Tweens = {}, Token = 0, ExitHooked = false }
		WindowStates[window] = newState
		state = newState
	end
	local win = state :: WindowState
	win.Token += 1
	cancelAll(win.Tweens)

	local header = window:FindFirstChild("Header")
	if header and header:IsA("GuiObject") then
		win.HeaderPosition = win.HeaderPosition or header.Position
		local home = win.HeaderPosition :: UDim2
		header.Position = home - UDim2.fromScale(0, 0.18)
		track(win.Tweens, TweenService:Create(
			header,
			TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0.08),
			{ Position = home }
		))

		local headerIcon = header:FindFirstChild("Icon")
		if headerIcon and headerIcon:IsA("GuiObject") then
			headerIcon.Rotation = -7
			track(win.Tweens, TweenService:Create(headerIcon, WOBBLE_INFO, { Rotation = 7 }))
		end

		local titleHolder = header:FindFirstChild("Title")
		local title = titleHolder and titleHolder:FindFirstChild("Title")
		local gradient = title and title:FindFirstChildOfClass("UIGradient")
		if gradient then
			win.GradientOffset = win.GradientOffset or gradient.Offset
			gradient.Offset = Vector2.new(-1, 0)
			track(win.Tweens, TweenService:Create(
				gradient,
				TweenInfo.new(2.4, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1),
				{ Offset = Vector2.new(1, 0) }
			))
		end
	end

	local exitButton = window:FindFirstChild("ExitButton")
	if exitButton and exitButton:IsA("GuiButton") and not win.ExitHooked then
		win.ExitHooked = true
		FX.AttachButtonFeel(exitButton, 1.12)
		exitButton.MouseEnter:Connect(function()
			TweenService:Create(exitButton, BUTTON_INFO, { Rotation = 10 }):Play()
		end)
		exitButton.MouseLeave:Connect(function()
			TweenService:Create(exitButton, BUTTON_INFO, { Rotation = 0 }):Play()
		end)
	end
end

function FX.CloseWindow(window: GuiObject)
	local win = WindowStates[window]
	if not win then
		return
	end
	win.Token += 1
	cancelAll(win.Tweens)

	local header = window:FindFirstChild("Header")
	if header and header:IsA("GuiObject") then
		if win.HeaderPosition then
			header.Position = win.HeaderPosition
		end
		local headerIcon = header:FindFirstChild("Icon")
		if headerIcon and headerIcon:IsA("GuiObject") then
			headerIcon.Rotation = 0
		end
	end
end

-- HUD button + badge: bouncing badge and a periodic wiggle while a reward is waiting.
function FX.SetAttention(button: GuiObject, badge: GuiObject?, enabled: boolean)
	local state = AttentionStates[button]
	if not state then
		state = { Token = 0, Tween = nil }
		AttentionStates[button] = state
	end
	local attention = state :: { Token: number, Tween: Tween? }
	attention.Token += 1
	local token = attention.Token

	if attention.Tween then
		attention.Tween:Cancel()
		attention.Tween = nil
	end
	button.Rotation = 0

	local badgeScale = if badge then getUIScale(badge) else nil
	if badgeScale then
		badgeScale.Scale = 1
	end
	if not enabled then
		return
	end

	if badgeScale then
		attention.Tween = TweenService:Create(
			badgeScale,
			TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = 1.25 }
		)
		;(attention.Tween :: Tween):Play()
	end

	task.spawn(function()
		while attention.Token == token do
			for _, angle in { -9, 8, -6, 4, 0 } do
				if attention.Token ~= token then
					return
				end
				local step = TweenService:Create(button, TweenInfo.new(0.07, Enum.EasingStyle.Sine), { Rotation = angle })
				step:Play()
				step.Completed:Wait()
			end
			task.wait(3)
		end
	end)
end

return FX
