--!strict
-- TimeStopFreeze (CLIENT ModuleScript) -> CombatController.TimeStop.TimeStopFreeze
-- Freezes all VFX, physics particles, and ambient sounds across the entire map locally:
--   * ParticleEmitter (TimeScale = 0)
--   * Trail & Beam (Enabled = false / paused)
--   * Fire, Smoke, Sparkles (Enabled = false)
--   * Positional Sounds across Workspace (Paused)
--   * Frozen characters' Humanoid AnimationTracks (Speed = 0)
-- Retains the caster's character and TimeStopFX folder.

local Freeze = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer :: Player
local active = nil

-- opts = { ignore = { Instance } }
function Freeze.Begin(opts)
	Freeze.End()
	local st = {
		ignore = opts and opts.ignore or {},
		emitters = {},
		trails = {},
		beams = {},
		legacyVFX = {},
		sounds = {},
		tracks = {},
		conns = {},
	}
	active = st

	local function isIgnored(instance: Instance): boolean
		for _, root in st.ignore do
			if root and (instance == root or instance:IsDescendantOf(root)) then
				return true
			end
		end
		return false
	end

	local function processInstance(inst: Instance)
		if active ~= st or isIgnored(inst) then return end

		if inst:IsA("ParticleEmitter") then
			if st.emitters[inst] == nil then
				st.emitters[inst] = inst.TimeScale
				inst.TimeScale = 0
			end
		elseif inst:IsA("Trail") then
			if st.trails[inst] == nil then
				st.trails[inst] = inst.Enabled
				inst.Enabled = false
			end
		elseif inst:IsA("Beam") then
			if st.beams[inst] == nil then
				st.beams[inst] = inst.Enabled
				inst.Enabled = false
			end
		elseif inst:IsA("Fire") or inst:IsA("Smoke") or inst:IsA("Sparkles") then
			if st.legacyVFX[inst] == nil then
				st.legacyVFX[inst] = inst.Enabled
				inst.Enabled = false
			end
		elseif inst:IsA("Sound") and inst:IsDescendantOf(Workspace) then
			if not st.sounds[inst] and inst.IsPlaying then
				st.sounds[inst] = true
				inst:Pause()
			end
		end
	end

	local function freezeTargetTracks()
		for _, player in Players:GetPlayers() do
			local char = player.Character
			if char and not isIgnored(char) and char:GetAttribute("TimeStopped") then
				local humanoid = char:FindFirstChildOfClass("Humanoid")
				local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
				if animator then
					for _, track in animator:GetPlayingAnimationTracks() do
						if st.tracks[track] == nil then
							st.tracks[track] = track.Speed
						end
						if track.Speed ~= 0 then
							track:AdjustSpeed(0)
						end
					end
				end
			end
		end
	end

	-- Lock animation speeds every frame against the default Animate script
	table.insert(st.conns, RunService.Heartbeat:Connect(function()
		freezeTargetTracks()
	end))

	-- Catch any new VFX spawned dynamically while time is stopped
	table.insert(st.conns, Workspace.DescendantAdded:Connect(function(descendant)
		task.defer(processInstance, descendant)
	end))

	-- Global sweep through Workspace
	task.spawn(function()
		local count = 0
		for _, desc in Workspace:GetDescendants() do
			if active ~= st then return end
			processInstance(desc)
			count += 1
			if count % 2000 == 0 then
				task.wait()
			end
		end
	end)
end

function Freeze.End()
	local st = active
	if not st then return end
	active = nil

	for _, connection in st.conns do
		connection:Disconnect()
	end

	-- Restore ParticleEmitters
	for emitter, timeScale in st.emitters do
		if emitter.Parent then
			emitter.TimeScale = timeScale
		end
	end

	-- Restore Trails
	for trail, wasEnabled in st.trails do
		if trail.Parent then
			trail.Enabled = wasEnabled
		end
	end

	-- Restore Beams
	for beam, wasEnabled in st.beams do
		if beam.Parent then
			beam.Enabled = wasEnabled
		end
	end

	-- Restore Legacy VFX (Fire, Smoke, Sparkles)
	for vfx, wasEnabled in st.legacyVFX do
		if vfx.Parent then
			vfx.Enabled = wasEnabled
		end
	end

	-- Restore AnimationTracks
	for track, speed in st.tracks do
		pcall(function()
			track:AdjustSpeed(speed)
		end)
	end

	-- Restore Paused Sounds
	for sound in st.sounds do
		if sound.Parent then
			sound:Resume()
		end
	end
end

return Freeze
