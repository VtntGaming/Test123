-- Owns independent charge visuals, release fades, and cleanup for each character.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local WeaponConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("WeaponConfig"))

--// Types
export type Options = {
	isActive: (() -> boolean)?,
	setFov: ((number, number) -> ())?,
	defaultFov: number?,
	onFull: (() -> ())?,
}

type State = {
	weapon: Model,
	startedAt: number,
	alpha: number,
	pop: number,
	flash: number,
	popped: boolean,
	releasing: boolean,
	setFov: ((number, number) -> ())?,
	defaultFov: number,
	fovReturn: number,
	fovTouched: boolean?,
	fovRestored: boolean?,
	conn: RBXScriptConnection?,
	light: PointLight?,
	highlight: Highlight?,
	charHighlight: Highlight?,
	sound: Sound?,
}

export type ChargeVFX = {
	Start: (character: Model, maxChargeTime: number, opts: (Options | (() -> boolean))?) -> (),
	-- Stop()/Stop(true) remain local-player shortcuts; remote effects require their character.
	Stop: (characterOrInstant: (Model | boolean)?, instant: boolean?) -> (),
}

--// Properties
local LocalPlayer = Players.LocalPlayer :: Player
local States: { [Model]: State } = {}

--// Controller
local ChargeVfx = {} :: ChargeVFX

local function scaleSequence(sequence: NumberSequence, k: number)
	local points = {}
	for _, kp in sequence.Keypoints do
		table.insert(points, NumberSequenceKeypoint.new(kp.Time, kp.Value * k, kp.Envelope * k))
	end
	return NumberSequence.new(points)
end

-- Originals are saved ONCE as attributes, so an interrupted charge can never become the new "normal".
local function baseline(d: ParticleEmitter)
	if d:GetAttribute("CV_Rate") == nil then
		d:SetAttribute("CV_Size", d.Size)
		d:SetAttribute("CV_Brightness", d.Brightness)
		d:SetAttribute("CV_LightEmission", d.LightEmission)
		d:SetAttribute("CV_Rate", d.Rate)
	end
	return d
end

local function restoreWeapon(weapon: Model)
	if not weapon then
		return
	end
	for _, d in weapon:GetDescendants() do
		if d:IsA("ParticleEmitter") and d:GetAttribute("CV_Rate") ~= nil then
			d.Size = d:GetAttribute("CV_Size")
			d.Brightness = d:GetAttribute("CV_Brightness")
			d.LightEmission = d:GetAttribute("CV_LightEmission")
			d.Rate = d:GetAttribute("CV_Rate")
		elseif d.Name == "CV_Light" or d.Name == "CV_Highlight" then
			d:Destroy()
		end
	end
	local highlight = weapon:FindFirstChild("CV_Highlight")
	if highlight then
		highlight:Destroy()
	end
end

local function restoreFov(s: State)
	if s.fovTouched and not s.fovRestored and s.setFov then
		s.fovRestored = true
		s.setFov(s.defaultFov, s.fovReturn)
	end
end

local function cleanup(character: Model, expected: State?)
	local old = States[character]
	if not old or (expected and old ~= expected) then
		return
	end
	States[character] = nil
	if old.conn then
		old.conn:Disconnect()
	end
	restoreWeapon(old.weapon)
	restoreFov(old)
	if old.charHighlight then
		old.charHighlight:Destroy()
	end
	local sound = old.sound
	if sound and sound.Parent then
		TweenService:Create(sound, TweenInfo.new(0.15), { Volume = 0 }):Play()
		Debris:AddItem(sound, 0.2)
	end
end

function ChargeVfx.Stop(characterOrInstant, instant)
	local character: Model?
	if type(characterOrInstant) == "boolean" then
		character = LocalPlayer.Character
		instant = characterOrInstant
	else
		character = characterOrInstant or LocalPlayer.Character
	end
	if not character then
		return
	end
	local current = States[character]
	if not current then
		return
	end
	if instant then
		cleanup(character, current)
		return
	end
	if current.releasing then
		return
	end
	current.releasing = true
	restoreFov(current) -- camera returns in sync with the fade
	local cfg = WeaponConfig.ChargeVfx
	-- Failsafe: even if the render loop dies, everything is force-reset.
	task.delay((cfg and cfg.ResetTime or 0.2) + 0.15, function()
		if States[character] == current then
			cleanup(character, current)
		end
	end)
end

-- opts = { isActive = fn, setFov = fn(value, duration), defaultFov = number, onFull = fn }
function ChargeVfx.Start(character, maxChargeTime, opts)
	local cfg = WeaponConfig.ChargeVfx
	if not cfg or not cfg.Enable then
		return
	end
	if type(opts) == "function" then
		opts = { isActive = opts }
	end
	local options: Options = opts or {}
	cleanup(character)

	local weapon = character:FindFirstChild("EquippedWeapon")
	if not weapon or not weapon:IsA("Model") then
		return
	end
	restoreWeapon(weapon)

	local root = weapon:FindFirstChild("Effects") or weapon
	local emitters = {}
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			baseline(d)
			table.insert(emitters, d)
		end
	end

	local anchor = weapon:FindFirstChild("Main") or weapon.PrimaryPart
	local current: State = {
		weapon = weapon,
		startedAt = os.clock(),
		alpha = 0,
		pop = 0,
		flash = 0,
		popped = false,
		releasing = false,
		setFov = if character == LocalPlayer.Character then options.setFov else nil,
		defaultFov = options.defaultFov or 70,
		fovReturn = cfg.Fov and cfg.Fov.ReturnTime or 0.2,
	}
	States[character] = current

	if cfg.Light and anchor and anchor:IsA("BasePart") then
		local light = Instance.new("PointLight")
		light.Name = "CV_Light"
		light.Color, light.Brightness, light.Range = cfg.Light.Color, 0, 0
		light.Parent = anchor
		current.light = light
	end
	if cfg.Highlight then
		local highlight = Instance.new("Highlight")
		highlight.Name = "CV_Highlight"
		highlight.Adornee = weapon
		highlight.FillTransparency = 1
		highlight.OutlineColor = cfg.Highlight.Color
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = weapon
		current.highlight = highlight
	end
	local ch = cfg.CharacterHighlight
	if ch then
		local h = Instance.new("Highlight")
		h.Name = "CV_CharHighlight"
		h.Adornee = character
		h.FillColor, h.OutlineColor = ch.Color, ch.Color
		h.FillTransparency, h.OutlineTransparency = 1, 1
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Parent = character
		current.charHighlight = h
	end

	-- FOV: slow zoom-in over the whole charge
	local fov = cfg.Fov
	if fov and current.setFov then
		current.fovTouched = true
		current.setFov(current.defaultFov - fov.ZoomIn, maxChargeTime)
	end

	local function onFull()
		current.popped = true
		current.pop = 1
		current.flash = 1
		for _, d in emitters do
			if d.Parent then
				d:Emit(cfg.PopBurst)
			end
		end

		-- sound
		if cfg.Sound then
			local sfx = SoundService:FindFirstChild("SFX")
			local source = sfx and sfx:FindFirstChild(cfg.Sound)
			if source and source:IsA("Sound") then
				local sound = source:Clone()
				sound.Looped = false
				sound.Volume = cfg.SoundVolume or source.Volume
				sound.Parent = if character == LocalPlayer.Character then SoundService else anchor or weapon
				sound:Play()
				sound.Ended:Once(function()
					sound:Destroy()
				end)
				Debris:AddItem(sound, 10)
				current.sound = sound
			end
		end

		-- camera punch, then settle back into the zoom
		local setFov = current.setFov
		if fov and setFov then
			setFov(current.defaultFov + fov.PunchOut, fov.PunchTime)
			task.delay(fov.PunchTime, function()
				if States[character] == current and not current.releasing then
					setFov(current.defaultFov - fov.ZoomIn, 0.25)
				end
			end)
		end

		if options.onFull then
			task.spawn(options.onFull)
		end
	end

	local function step(dt: number)
		if not character.Parent or not weapon:IsDescendantOf(character) then
			cleanup(character, current)
			return
		end

		if not current.releasing and options.isActive and not options.isActive() then
			ChargeVfx.Stop(character) -- charge ended through any path: fade back
		end

		if current.releasing then
			current.alpha -= dt / math.max(cfg.ResetTime, 0.01)
			if current.alpha <= 0 then
				cleanup(character, current)
				return
			end
		else
			local p = math.clamp((os.clock() - current.startedAt) / maxChargeTime, 0, 1)
			current.alpha = 1 - (1 - p) ^ 2
			if p >= 1 and not current.popped then
				onFull()
			end
		end

		current.pop = math.max(0, current.pop - dt * 6)
		current.flash = math.max(0, current.flash - dt * 4)
		local alpha = math.clamp(current.alpha, 0, 1)
		local k = 1 + (cfg.MaxScale - 1) * alpha + cfg.PopScale * current.pop
		local pulse = 1 + math.sin(os.clock() * cfg.PulseSpeed) * cfg.PulseAmount * alpha
		local brightness = (1 + (cfg.MaxBrightness - 1) * alpha) * pulse

		for _, d in emitters do
			if d.Parent then
				d.Size = scaleSequence(d:GetAttribute("CV_Size"), k)
				d.Brightness = d:GetAttribute("CV_Brightness") * brightness
				d.LightEmission = math.min(1, d:GetAttribute("CV_LightEmission") + cfg.LightEmissionBoost * alpha)
				d.Rate = d:GetAttribute("CV_Rate") * (1 + (cfg.RateMultiplier - 1) * alpha)
			end
		end
		if current.light then
			current.light.Brightness = cfg.Light.Brightness * alpha * pulse
			current.light.Range = cfg.Light.Range * alpha
		end
		if current.highlight then
			current.highlight.OutlineTransparency = 1 - (1 - cfg.Highlight.Transparency) * alpha
		end
		if current.charHighlight and ch then
			local fill = 1 - (1 - ch.FillTransparency) * alpha
			fill += (ch.FlashFillTransparency - fill) * current.flash -- bright flash at full charge
			local color = ch.Color:Lerp(ch.FlashColor, current.flash)
			current.charHighlight.FillColor = color
			current.charHighlight.OutlineColor = color
			current.charHighlight.FillTransparency = fill
			current.charHighlight.OutlineTransparency = 1 - (1 - ch.OutlineTransparency) * alpha
		end
	end

	current.conn = RunService.RenderStepped:Connect(function(dt: number)
		if States[character] ~= current then
			return
		end
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[ChargeVfx] error, resetting:", err)
			cleanup(character, current)
		end
	end)
end

return ChargeVfx
