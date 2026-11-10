--!strict
-- Pauses local particles, trails and ambient sounds; shared simulation owns character animation freezing.
local Workspace = game:GetService("Workspace")
type State = { Ignore: { Instance }, Restores: { () -> () }, Connection: RBXScriptConnection? }
export type Freeze = { Begin: ({ ignore: { Instance } }?) -> (), End: () -> () }
local Active: State?
local Freeze: Freeze = {} :: Freeze
function Freeze.End()
	local state = Active
	if not state then
		return
	end
	Active = nil
	if state.Connection then
		state.Connection:Disconnect()
	end
	for _, restore in state.Restores do
		restore()
	end
	table.clear(state.Restores)
end
function Freeze.Begin(options)
	Freeze.End()
	local state: State = { Ignore = if options then options.ignore else {}, Restores = {}, Connection = nil }
	Active = state
	local seen: { [Instance]: boolean } = {}
	local function process(instance: Instance)
		if Active ~= state or seen[instance] then
			return
		end
		for _, root in state.Ignore do
			if instance == root or instance:IsDescendantOf(root) then
				return
			end
		end
		seen[instance] = true
		if instance:IsA("ParticleEmitter") then
			local value = instance.TimeScale
			instance.TimeScale = 0
			table.insert(state.Restores, function()
				if instance.Parent and instance.TimeScale == 0 then
					instance.TimeScale = value
				end
			end)
		elseif instance:IsA("Trail") then
			local value = instance.Enabled
			instance.Enabled = false
			table.insert(state.Restores, function()
				if instance.Parent and not instance.Enabled then
					instance.Enabled = value
				end
			end)
		elseif instance:IsA("Beam") then
			local value = instance.Enabled
			instance.Enabled = false
			table.insert(state.Restores, function()
				if instance.Parent and not instance.Enabled then
					instance.Enabled = value
				end
			end)
		elseif instance:IsA("Fire") then
			local value = instance.Enabled
			instance.Enabled = false
			table.insert(state.Restores, function()
				if instance.Parent and not instance.Enabled then
					instance.Enabled = value
				end
			end)
		elseif instance:IsA("Smoke") then
			local value = instance.Enabled
			instance.Enabled = false
			table.insert(state.Restores, function()
				if instance.Parent and not instance.Enabled then
					instance.Enabled = value
				end
			end)
		elseif instance:IsA("Sparkles") then
			local value = instance.Enabled
			instance.Enabled = false
			table.insert(state.Restores, function()
				if instance.Parent and not instance.Enabled then
					instance.Enabled = value
				end
			end)
		elseif instance:IsA("Sound") and instance.IsPlaying then
			instance:Pause()
			table.insert(state.Restores, function()
				if instance.Parent and instance.IsPaused then
					instance:Resume()
				end
			end)
		end
	end
	state.Connection = Workspace.DescendantAdded:Connect(function(instance: Instance)
		task.defer(process, instance)
	end)
	task.spawn(function()
		for index, instance in Workspace:GetDescendants() do
			if Active ~= state then
				return
			end
			process(instance)
			if index % 2000 == 0 then
				task.wait()
			end
		end
	end)
end
return Freeze
