local ArenaFallingController = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local config =
	require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig")).ArenaFalling
local FallingEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("FallingEvent")
-- Original local appearance used when restoring or rebuilding platform visuals.
type SavedPart = {
	color: Color3, -- Part color before warning flashes.
	transparency: number -- Original LocalTransparencyModifier, not the replicated Transparency property.
}
-- Visual instances whose Enabled state is saved while the original platform is hidden.
type Effect = ParticleEmitter | Trail | Beam | Light | SurfaceGui | BillboardGui
-- Local visual state for one server-announced falling platform.
type State = {
	phase: string, -- Current Warning or Fall presentation phase.
	revision: number, -- Server arena-sequence number used to reject older updates.
	startedAt: number, -- Server timestamp when the current visual phase began.
	origin: CFrame, -- Original platform pivot used to calculate local warning and fall movement.
	clientVisuals: boolean, -- Whether this client animates a separate visual copy.
	parts: { [BasePart]: SavedPart }, -- Original colors and local transparency of the real platform parts.
	effects: { [Effect]: boolean }, -- Original Enabled values of effects hidden on the real platform.
	copy: Model?, -- Client-only animated platform clone, when client visuals are enabled.
	copyParts: { [BasePart]: SavedPart }, -- Saved appearance of the clone's parts for warning flashes and fading.
	rebuild: boolean, -- Whether streamed descendant changes require refreshing the visual copy.
}
local states: { [Model]: State } = {}
local observed: { [Model]: { RBXScriptConnection } } = {}
local initialized = false
local visualFolder: Folder? = nil

local function clear(model: Model)
	local state = states[model]
	states[model] = nil
	if not state then
		return
	end
	if state.copy then
		state.copy:Destroy()
	end
	for part, saved in state.parts do
		if part.Parent then
			part.Color, part.LocalTransparencyModifier = saved.color, saved.transparency
		end
	end
	for effect, enabled in state.effects do
		if effect.Parent then
			effect.Enabled = enabled
		end
	end
end

local function refresh(model: Model, phase, revision, startedAt, clientVisuals, origin)
	phase = phase or model:GetAttribute("FallingPhase")
	revision = revision or model:GetAttribute("FallingRevision")
	startedAt = startedAt or model:GetAttribute("FallingStartedAt")
	if clientVisuals == nil then
		clientVisuals = model:GetAttribute("FallingClientVisuals") == true
	end
	origin = origin or model:GetAttribute("FallingOrigin")
	if typeof(revision) ~= "number" or typeof(startedAt) ~= "number" or typeof(origin) ~= "CFrame" then
		return
	end
	local state = states[model]
	if
		state and (revision < state.revision or (revision == state.revision and startedAt < state.startedAt))
	then
		return
	end
	if not model:IsDescendantOf(workspace) or (phase ~= "Warning" and phase ~= "Fall") then
		clear(model)
		return
	end
	if state and (revision ~= state.revision or clientVisuals ~= state.clientVisuals) then
		clear(model)
		state = nil
	end
	if not state then
		state = {
			phase = phase,
			revision = revision,
			startedAt = startedAt,
			origin = origin,
			clientVisuals = clientVisuals,
			parts = {},
			effects = {},
			copy = nil,
			copyParts = {},
			rebuild = true,
		}
		states[model] = state
	end
	state.phase, state.startedAt, state.origin = phase, startedAt, origin
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") and not state.parts[item] then
			state.parts[item] = { color = item.Color, transparency = item.LocalTransparencyModifier }
		end
	end
end

local function detach(model: Model)
	clear(model)
	local connections = observed[model]
	observed[model] = nil
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
	end
end

local function observe(instance: Instance)
	if not instance:IsA("Model") or not instance:IsDescendantOf(workspace) then
		return
	end
	local model = instance
	if observed[model] then
		refresh(model)
		return
	end
	local connections = {}
	observed[model] = connections
	for _, attribute in
		{ "FallingPhase", "FallingStartedAt", "FallingRevision", "FallingClientVisuals", "FallingOrigin" }
	do
		table.insert(
			connections,
			model:GetAttributeChangedSignal(attribute):Connect(function()
				refresh(model)
			end)
		)
	end
	local function descendantsChanged()
		local state = states[model]
		if state then
			state.rebuild = true
		end
		-- Batch streamed descendants; rebuilding occurs once in the visual update.
	end
	table.insert(connections, model.DescendantAdded:Connect(descendantsChanged))
	table.insert(connections, model.DescendantRemoving:Connect(descendantsChanged))
	table.insert(
		connections,
		model.Destroying:Connect(function()
			detach(model)
		end)
	)
	table.insert(
		connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(workspace) then
				detach(model)
			end
		end)
	)
	refresh(model)
end

local function createCopy(model: Model, state: State): boolean
	-- Restore originals before cloning so a rebuild never copies our local hiding/fade.
	for part, saved in state.parts do
		if part.Parent then
			part.Color, part.LocalTransparencyModifier = saved.color, saved.transparency
		end
	end
	for effect, enabled in state.effects do
		if effect.Parent then
			effect.Enabled = enabled
		end
	end
	local archivable = model.Archivable
	model.Archivable = true
	local copy = model:Clone()
	model.Archivable = archivable
	if not copy then
		return false
	end
	copy.Name = model.Name .. "_FallingVisual"
	local descendants = copy:GetDescendants()
	table.insert(descendants, copy)
	local copyParts: { [BasePart]: SavedPart } = {}
	for _, item in descendants do
		if item ~= copy and not item:IsDescendantOf(copy) then
			continue
		end
		for _, tag in CollectionService:GetTags(item) do
			CollectionService:RemoveTag(item, tag)
		end
		if
			item:IsA("LuaSourceContainer")
			or item:IsA("Sound")
			or item:IsA("Constraint")
			or item:IsA("JointInstance")
			or item:IsA("WeldConstraint")
			or item:IsA("BodyMover")
			or item:IsA("ClickDetector")
			or item:IsA("ProximityPrompt")
		then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide, item.CanTouch, item.CanQuery = false, false, false
			copyParts[item] = { color = item.Color, transparency = item.LocalTransparencyModifier }
		end
	end
	if state.copy then
		state.copy:Destroy()
	end
	local folder = visualFolder
	if not folder or not folder.Parent then
		folder = Instance.new("Folder")
		folder.Name = "LocalFallingPlatformVisuals"
		folder.Parent = workspace
		visualFolder = folder
	end
	copy.Parent = folder
	state.copy, state.copyParts, state.rebuild = copy, copyParts, false
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			if not state.parts[item] then
				state.parts[item] = { color = item.Color, transparency = item.LocalTransparencyModifier }
			end
			item.LocalTransparencyModifier = 1
		elseif
			item:IsA("ParticleEmitter")
			or item:IsA("Trail")
			or item:IsA("Beam")
			or item:IsA("Light")
			or item:IsA("SurfaceGui")
			or item:IsA("BillboardGui")
		then
			if state.effects[item] == nil then
				state.effects[item] = item.Enabled
			end
			item.Enabled = false
		end
	end
	return true
end

local function warningFrame(origin, elapsed)
	local speed, intensity = config.ShakeSpeed, config.ShakeIntensity
	return origin
		+ Vector3.new(
			math.sin(elapsed * speed) * intensity,
			math.cos(elapsed * speed * 1.1) * intensity * 0.5 + elapsed * 1.5,
			math.sin(elapsed * speed * 0.9) * intensity
		)
end

function ArenaFallingController.Init()
	if initialized then
		return
	end
	initialized = true
	CollectionService:GetInstanceAddedSignal("CombatFallingPlatform"):Connect(observe)
	CollectionService:GetInstanceRemovedSignal("CombatFallingPlatform"):Connect(function(instance)
		if instance:IsA("Model") then
			detach(instance)
		end
	end)
	for _, model in CollectionService:GetTagged("CombatFallingPlatform") do
		observe(model)
	end
	FallingEvent.OnClientEvent:Connect(function(action, model, revision, startedAt, clientVisuals, origin)
		if typeof(model) ~= "Instance" or not model:IsA("Model") or not model:IsDescendantOf(workspace) then
			return
		end
		observe(model)
		refresh(model, action, revision, startedAt, clientVisuals, origin)
	end)
	RunService.Heartbeat:Connect(function()
		local now = workspace:GetServerTimeNow()
		for model, state in states do
			if not model:IsDescendantOf(workspace) then
				detach(model)
				continue
			end
			if state.rebuild then
				refresh(
					model,
					state.phase,
					state.revision,
					state.startedAt,
					state.clientVisuals,
					state.origin
				)
			end
			if state.clientVisuals and (state.rebuild or not state.copy) then
				if not createCopy(model, state) then
					continue
				end
			else
				state.rebuild = false
			end
			local elapsed = math.max(0, now - state.startedAt)
			local flash = (math.sin(elapsed * 12) + 1) * 0.5
			local fade = math.clamp(
				(elapsed - config.FadeDelay) / math.max(0.001, config.DropDuration - config.FadeDelay),
				0,
				1
			)
			if state.clientVisuals and state.copy then
				if state.phase == "Warning" then
					state.copy:PivotTo(warningFrame(state.origin, math.min(elapsed, config.WarningDuration)))
				else
					local alpha = math.clamp(elapsed / math.max(config.DropDuration, 0.001), 0, 1)
					local fallOrigin = warningFrame(state.origin, config.WarningDuration)
					state.copy:PivotTo(
						fallOrigin - Vector3.yAxis * (config.DropDistance * (1 - (1 - alpha) ^ 2))
					)
				end
			end
			local parts = if state.clientVisuals then state.copyParts else state.parts
			for part, saved in parts do
				if part.Parent then
					if state.phase == "Warning" and part.Name == "Neon" then
						part.Color = saved.color:Lerp(Color3.fromRGB(255, 0, 0), flash)
					elseif state.phase == "Fall" then
						part.LocalTransparencyModifier = saved.transparency + (1 - saved.transparency) * fade
					end
				end
			end
		end
	end)
end

return ArenaFallingController
