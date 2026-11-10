--!strict
-- Replicates ordinary public state through scalar Value objects instead of shared attribute payloads.
-- This store is for services and presentation code outside BindToSimulation; predicted state uses Simulation.Attributes.

--// Services
local RunService = game:GetService("RunService")

--// References
local IsServer = RunService:IsServer()

--// Constants
local CONTAINER_NAME = "PublicValues"

--// Types
type Value = boolean | number | string
type Watch = {
	Signals: { [string]: BindableEvent },
	All: BindableEvent,
	Seen: { [string]: Value? },
	Connections: { RBXScriptConnection },
	ContainerConnections: { RBXScriptConnection },
	Values: { [Instance]: RBXScriptConnection },
}
export type ReplicatedValues = {
	Get: (Instance, string) -> unknown?,
	GetNumber: (Instance, string) -> number?,
	GetString: (Instance, string) -> string?,
	GetBoolean: (Instance, string) -> boolean?,
	Set: (Instance, string, unknown) -> (),
	GetAll: (Instance) -> { [string]: Value },
	GetChangedSignal: (Instance, string) -> RBXScriptSignal,
	GetAllChangedSignal: (Instance) -> RBXScriptSignal,
	CopyToVisual: (Instance, Model) -> (),
}

--// Properties
local Watches: { [Instance]: Watch } = {}

--// Store
local ReplicatedValues: ReplicatedValues = {} :: ReplicatedValues

local function FindContainer(source: Instance): Folder?
	local container = source:FindFirstChild(CONTAINER_NAME)
	return if container and container:IsA("Folder") then container else nil
end

local function Read(item: Instance?): Value?
	if not item then
		return nil
	end
	if item:IsA("BoolValue") then
		return item.Value
	elseif item:IsA("NumberValue") then
		return item.Value
	elseif item:IsA("StringValue") then
		return item.Value
	end
	return nil
end

local function Write(source: Instance, key: string, value: unknown)
	assert(key ~= "", "Public value key must not be empty")
	assert(
		value == nil or type(value) == "boolean" or type(value) == "number" or type(value) == "string",
		"Unsupported public value: " .. key
	)
	local container = FindContainer(source)
	if not container then
		if value == nil then
			return
		end
		local createdContainer = Instance.new("Folder")
		createdContainer.Name = CONTAINER_NAME
		createdContainer.Parent = source
		container = createdContainer
	end
	assert(container ~= nil)
	local item = container:FindFirstChild(key)
	if value == nil then
		if item then
			item:Destroy()
		end
		return
	end
	if Read(item) == value then
		return
	end
	if item then
		if item:IsA("BoolValue") and type(value) == "boolean" then
			item.Value = value
			return
		elseif item:IsA("NumberValue") and type(value) == "number" then
			item.Value = value
			return
		elseif item:IsA("StringValue") and type(value) == "string" then
			item.Value = value
			return
		end
		item:Destroy()
	end
	local created: Instance
	if type(value) == "boolean" then
		local entry = Instance.new("BoolValue")
		entry.Value = value
		created = entry
	elseif type(value) == "number" then
		local entry = Instance.new("NumberValue")
		entry.Value = value
		created = entry
	else
		assert(type(value) == "string")
		local entry = Instance.new("StringValue")
		entry.Value = value
		created = entry
	end
	created.Name = key
	created.Parent = container
end

local function WatchSource(source: Instance): Watch
	local existing = Watches[source]
	if existing then
		return existing
	end
	local watch: Watch = {
		Signals = {},
		All = Instance.new("BindableEvent"),
		Seen = ReplicatedValues.GetAll(source),
		Connections = {},
		ContainerConnections = {},
		Values = {},
	}
	Watches[source] = watch
	local function refresh(key: string)
		if Watches[source] ~= watch then
			return
		end
		local container = FindContainer(source)
		local value = Read(if container then container:FindFirstChild(key) else nil)
		if watch.Seen[key] == value then
			return
		end
		watch.Seen[key] = value
		local signal = watch.Signals[key]
		if signal then
			signal:Fire()
		end
		watch.All:Fire(key)
	end
	local function attachContainer()
		if Watches[source] ~= watch then
			return
		end
		for _, connection in watch.ContainerConnections do
			connection:Disconnect()
		end
		table.clear(watch.ContainerConnections)
		for _, connection in watch.Values do
			connection:Disconnect()
		end
		table.clear(watch.Values)
		local container = FindContainer(source)
		local function attach(item: Instance)
			if watch.Values[item] then
				return
			end
			if item:IsA("BoolValue") or item:IsA("NumberValue") or item:IsA("StringValue") then
				watch.Values[item] = item:GetPropertyChangedSignal("Value"):Connect(function()
					refresh(item.Name)
				end)
				refresh(item.Name)
			end
		end
		if container then
			table.insert(watch.ContainerConnections, container.ChildAdded:Connect(attach))
			table.insert(
				watch.ContainerConnections,
				container.ChildRemoved:Connect(function(item: Instance)
					local connection = watch.Values[item]
					if connection then
						connection:Disconnect()
						watch.Values[item] = nil
					end
					refresh(item.Name)
				end)
			)
			for _, item in container:GetChildren() do
				attach(item)
			end
		end
		for key in watch.Seen do
			refresh(key)
		end
	end
	local function containerChanged(child: Instance)
		if child.Name == CONTAINER_NAME then
			attachContainer()
		end
	end
	table.insert(watch.Connections, source.ChildAdded:Connect(containerChanged))
	table.insert(watch.Connections, source.ChildRemoved:Connect(containerChanged))
	table.insert(
		watch.Connections,
		source.Destroying:Connect(function()
			Watches[source] = nil
			for _, connection in watch.Connections do
				connection:Disconnect()
			end
			for _, connection in watch.ContainerConnections do
				connection:Disconnect()
			end
			for _, connection in watch.Values do
				connection:Disconnect()
			end
			for _, signal in watch.Signals do
				signal:Destroy()
			end
			watch.All:Destroy()
		end)
	)
	attachContainer()
	return watch
end

--// APIs
function ReplicatedValues.Get(source, key)
	local container = FindContainer(source)
	return Read(if container then container:FindFirstChild(key) else nil)
end

function ReplicatedValues.Set(source, key, value)
	assert(IsServer, "Public values are server-owned")
	Write(source, key, value)
end

function ReplicatedValues.GetNumber(source, key)
	local value = ReplicatedValues.Get(source, key)
	return if type(value) == "number" then value else nil
end

function ReplicatedValues.GetString(source, key)
	local value = ReplicatedValues.Get(source, key)
	return if type(value) == "string" then value else nil
end

function ReplicatedValues.GetBoolean(source, key)
	local value = ReplicatedValues.Get(source, key)
	return if type(value) == "boolean" then value else nil
end

function ReplicatedValues.GetAll(source)
	local values: { [string]: Value } = {}
	local container = FindContainer(source)
	if container then
		for _, item in container:GetChildren() do
			local value = Read(item)
			if value ~= nil then
				values[item.Name] = value
			end
		end
	end
	return values
end

function ReplicatedValues.GetChangedSignal(source, key)
	local watch = WatchSource(source)
	local signal = watch.Signals[key]
	if not signal then
		signal = Instance.new("BindableEvent")
		watch.Signals[key] = signal
	end
	return signal.Event
end

function ReplicatedValues.GetAllChangedSignal(source)
	return WatchSource(source).All.Event
end

function ReplicatedValues.CopyToVisual(source, target)
	assert(not IsServer and target:GetAttribute("CartoonVisualOnly") == true, "Expected a local Cartoon visual rig")
	local values = ReplicatedValues.GetAll(source)
	for key in ReplicatedValues.GetAll(target) do
		if values[key] == nil then
			Write(target, key, nil)
		end
	end
	for key, value in values do
		Write(target, key, value)
	end
end

return ReplicatedValues
