--!strict
-- Owns readable replicated player values and inventory counts, including publication readiness and observers.

--// Services
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

--// Modules
local Schema = require(script.Parent.Schema)
local Types = require(script.Parent.Types)
local InventoryValues = require(script.Parent.InventoryValues)

--// References
local IsServer = RunService:IsServer()
local ServerStorage = if IsServer then game:GetService("ServerStorage") else nil

--// Types
type Scalar = Types.Value
type Descriptor = { Kind: string, Members: { string }? }
type Manifest = { [string]: Descriptor }
type Watch = { Key: string, Connection: RBXScriptConnection }
type InventoryCache = { Encoded: string, Lookup: InventoryValues.Counts }
type Record = {
	Private: Instance?,
	Inventories: { [string]: InventoryCache },
	Ready: boolean?,
	PublishScheduled: boolean,
	Connections: { RBXScriptConnection },
	Container: Instance?,
	Objects: { [Instance]: boolean },
	Watched: { [Instance]: Watch },
	Keys: { [string]: boolean },
	Pending: { [string]: boolean },
	Scheduled: boolean,
	Refresh: boolean,
	Changed: (string) -> (),
}
export type Values = {
	-- Creates server storage or attaches client observers once, notifying logical field changes.
	Attach: (Player, (string) -> ()) -> (),
	-- Reads a scalar or reconstructs an inventory string; absent fields return nil.
	Get: (Player, string) -> Scalar?,
	-- Returns cached ownership quantity, or zero when the inventory/member is absent.
	GetItemCount: (Player, Types.InventoryKey, string) -> number,
	-- Reads logical values only, excluding metadata and local UI overrides.
	GetAll: (Player) -> Types.Values,
	-- Updates a field and its revision, returning whether its logical value changed.
	Set: (Player, string, Scalar?) -> boolean,
	-- Returns whether the server record exists or the client has the published field/member instances.
	IsReady: (Player) -> boolean,
	-- Returns a logical field's native revision, or zero when absent.
	Revision: (Player, string) -> number,
	-- Disconnects owned observers and destroys the server's native container.
	Remove: (Player) -> (),
}

--// Properties
local Records: { [Player]: Record } = {}

--// Store
local Values: Values = {} :: Values

local function Container(player: Player): Instance?
	return player:FindFirstChild("PlayerData")
end

local function Group(player: Player, key: string): Instance?
	local field = Schema.Fields[key]
	local record = Records[player]
	local container = if field and field.Visibility == "Server" then (if IsServer and record then record.Private else nil) else Container(player)
	return if container then container:FindFirstChild(Schema.Group(key)) else nil
end

local function Field(player: Player, key: string): Instance?
	local group = Group(player, key)
	return if group then group:FindFirstChild(key) else nil
end

local function Metadata(player: Player, key: string?): Instance?
	local field = if key then Schema.Fields[key] else nil
	local record = Records[player]
	local container = if field and field.Visibility == "Server" then (if IsServer and record then record.Private else nil) else Container(player)
	return if container then container:FindFirstChild("Metadata") else nil
end

local function Read(item: Instance?): Scalar?
	if not item then
		return nil
	elseif item:IsA("BoolValue") then
		return item.Value
	elseif item:IsA("NumberValue") then
		return item.Value
	elseif item:IsA("StringValue") then
		return item.Value
	end
	return nil
end

local function Counts(folder: Instance): InventoryValues.Counts
	local counts: InventoryValues.Counts = {}
	for _, child in folder:GetChildren() do
		if child:IsA("NumberValue") then
			counts[child.Name] = child.Value
		end
	end
	return counts
end

local function CreateScalar(key: string, value: Scalar): Instance
	local item: Instance
	if type(value) == "boolean" then
		local entry = Instance.new("BoolValue")
		entry.Value = value
		item = entry
	elseif type(value) == "number" then
		local entry = Instance.new("NumberValue")
		entry.Value = value
		item = entry
	else
		local entry = Instance.new("StringValue")
		entry.Value = value
		item = entry
	end
	item.Name = key
	return item
end

local function Publish(player: Player)
	local metadata = Metadata(player)
	local marker = if metadata then metadata:FindFirstChild("PublishedFields") else nil
	assert(marker and marker:IsA("StringValue"), "Player data publication marker is not available")
	if Values.Get(player, "DataLoaded") ~= true then
		marker.Value = ""
		return
	end
	local manifest: Manifest = {}
	for _, name in Schema.Groups do
		local container = Container(player)
		local group = if container then container:FindFirstChild(name) else nil
		if group then
			for _, item in group:GetChildren() do
				if InventoryValues.Contains(item.Name) and item:IsA("Folder") then
					local members: { string } = {}
					for _, member in item:GetChildren() do
						table.insert(members, member.Name)
					end
					table.sort(members)
					manifest[item.Name] = { Kind = "Folder", Members = members }
				else
					manifest[item.Name] = { Kind = item.ClassName }
				end
			end
		end
	end
	marker.Value = HttpService:JSONEncode(manifest)
end

local function SchedulePublication(player: Player)
	local record = Records[player]
	if not record or record.PublishScheduled then return end
	record.PublishScheduled = true
	task.defer(function()
		if Records[player] ~= record then return end
		record.PublishScheduled = false
		Publish(player)
	end)
end

local function LogicalKey(container: Instance, item: Instance): string?
	local parent = item.Parent
	if not parent then
		return nil
	end
	if parent.Name == "Metadata" and parent.Parent == container then
		return if item.Name == "PublishedFields" then "DataLoaded" else nil
	end
	if parent.Name == "Revisions" and parent.Parent and parent.Parent.Name == "Metadata" then
		return item.Name
	end
	if parent.Parent == container and parent.Name ~= "Metadata" then
		return item.Name
	end
	if InventoryValues.Contains(parent.Name) and parent.Parent and parent.Parent.Parent == container then
		return parent.Name
	end
	return nil
end

local function Schedule(player: Player, record: Record, key: string?, refresh: boolean)
	if refresh then table.clear(record.Inventories) elseif key then record.Inventories[key] = nil end
	if refresh or key == "DataLoaded" then record.Ready = nil end
	if key then
		record.Pending[key] = true
	end
	record.Refresh = record.Refresh or refresh
	if record.Scheduled then
		return
	end
	record.Scheduled = true
	task.defer(function()
		if Records[player] ~= record then
			return
		end
		if record.Refresh then
			record.Refresh = false
			local container = Container(player)
			record.Container = container
			local objects: { [Instance]: boolean } = {}
			local present: { [Instance]: boolean } = {}
			local keys: { [string]: boolean } = {}
			local containers: { Instance } = {}
			if container then table.insert(containers, container) end
			if record.Private then table.insert(containers, record.Private) end
			for _, source in containers do
				for _, item in source:GetDescendants() do
					objects[item] = true
					local logical = LogicalKey(source, item)
					if logical then
						present[item] = true
						keys[logical] = true
						if
							not record.Watched[item]
							and (item:IsA("BoolValue") or item:IsA("NumberValue") or item:IsA("StringValue"))
						then
							record.Watched[item] = {
								Key = logical,
								Connection = item:GetPropertyChangedSignal("Value"):Connect(function()
									Schedule(player, record, logical, false)
								end),
							}
						end
					end
				end
			end
			for item, watch in record.Watched do
				if not present[item] then
					watch.Connection:Disconnect()
					record.Watched[item] = nil
				end
			end
			for logical in record.Keys do
				record.Pending[logical] = true
			end
			for logical in keys do
				record.Pending[logical] = true
			end
			record.Keys = keys
			record.Objects = objects
		end
		local pending = record.Pending
		record.Pending = {}
		record.Scheduled = false
		for logical in pending do
			record.Changed(logical)
		end
		-- Any field/member arrival can complete the current publication.
		record.Changed("DataLoaded")
	end)
end

--// APIs
function Values.Attach(player, changed)
	if Records[player] then
		return
	end
	local record: Record = {
		Private = nil, Inventories = {}, Ready = nil, PublishScheduled = false,
		Connections = {},
		Container = nil,
		Objects = {},
		Watched = {},
		Keys = {},
		Pending = {},
		Scheduled = false,
		Refresh = false,
		Changed = changed,
	}
	Records[player] = record
	if IsServer then
		local container = Instance.new("Folder")
		container.Name = "PlayerData"
		for _, name in Schema.Groups do
			local group = Instance.new("Folder")
			group.Name = name
			group.Parent = container
		end
		local metadata = Instance.new("Folder")
		metadata.Name = "Metadata"
		local revisions = Instance.new("Folder")
		revisions.Name = "Revisions"
		revisions.Parent = metadata
		local marker = Instance.new("StringValue")
		marker.Name = "PublishedFields"
		marker.Parent = metadata
		metadata.Parent = container
		container.Parent = player
		if ServerStorage then
			local privateRoot = ServerStorage:FindFirstChild("PlayerData")
			if not privateRoot then
				privateRoot = Instance.new("Folder")
				privateRoot.Name, privateRoot.Parent = "PlayerData", ServerStorage
			end
			local private = Instance.new("Folder")
			private.Name = tostring(player.UserId)
			for _, field in Schema.Fields do
				if field.Visibility == "Server" and not private:FindFirstChild(field.Group) then
					local group = Instance.new("Folder")
					group.Name, group.Parent = field.Group, private
				end
			end
			local privateMetadata = Instance.new("Folder")
			privateMetadata.Name, privateMetadata.Parent = "Metadata", private
			local privateRevisions = Instance.new("Folder")
			privateRevisions.Name, privateRevisions.Parent = "Revisions", privateMetadata
			private.Parent = privateRoot
			record.Private = private
		end
	end
	local function topologyChanged(instance: Instance)
		local container = Container(player)
		if
			(instance.Name == "PlayerData" and instance.Parent == player)
			or instance == record.Container
			or record.Objects[instance]
			or (container and (instance == container or instance:IsDescendantOf(container)))
			or (record.Private and (instance == record.Private or instance:IsDescendantOf(record.Private)))
		then
			Schedule(player, record, nil, true)
		end
	end
	table.insert(record.Connections, player.DescendantAdded:Connect(topologyChanged))
	table.insert(record.Connections, player.DescendantRemoving:Connect(topologyChanged))
	if record.Private then
		table.insert(record.Connections, record.Private.DescendantAdded:Connect(topologyChanged))
		table.insert(record.Connections, record.Private.DescendantRemoving:Connect(topologyChanged))
	end
	Schedule(player, record, nil, true)
end

local function Inventory(player: Player, key: string): InventoryCache?
	local record = Records[player]
	local cached = record and record.Inventories[key]
	if cached then return cached end
	local item = Field(player, key)
	if not item or not item:IsA("Folder") then return nil end
	local counts = Counts(item)
	local result = { Encoded = InventoryValues.Encode(key, counts), Lookup = InventoryValues.Lookup(key, counts) }
	if record then record.Inventories[key] = result end
	return result
end

function Values.Get(player, key)
	if InventoryValues.Contains(key) then
		local cached = Inventory(player, key)
		return if cached then cached.Encoded else nil
	end
	return Read(Field(player, key))
end

function Values.GetItemCount(player, key, itemName)
	local cached = Inventory(player, key)
	return if cached then cached.Lookup[itemName] or 0 else 0
end

function Values.GetAll(player)
	local result: Types.Values = {}
	local containers: { Instance } = {}
	local public = Container(player)
	if public then table.insert(containers, public) end
	local record = Records[player]
	if IsServer and record and record.Private then table.insert(containers, record.Private) end
	for _, container in containers do
		for _, name in Schema.Groups do
			local group = container:FindFirstChild(name)
			if group then
				for _, item in group:GetChildren() do result[item.Name] = Values.Get(player, item.Name) end
			end
		end
	end
	return result
end

function Values.Set(player, key, value)
	local group = Group(player, key)
	local metadata = Metadata(player, key)
	local revisions = if metadata then metadata:FindFirstChild("Revisions") else nil
	assert(group and revisions, "Player data container is not available")
	local item = group:FindFirstChild(key)
	local topology = false
	local counts: InventoryValues.Counts? = nil
	if value ~= nil and InventoryValues.Contains(key) then
		assert(type(value) == "string", "Player inventory must be a string: " .. key)
		local decodedCounts = InventoryValues.Decode(key, value)
		counts = decodedCounts
		if item then
			local current = Counts(item)
			local same = true
			for name, count in decodedCounts do
				if current[name] ~= count then
					same = false
				end
			end
			for name in current do
				if decodedCounts[name] == nil then
					same = false
				end
			end
			if same then
				return false
			end
		end
	elseif (value == nil and item == nil) or (value ~= nil and Read(item) == value) then
		return false
	end
	local revision: Instance = revisions:FindFirstChild(key) or Instance.new("NumberValue")
	revision.Name = key
	revision.Parent = revisions
	assert(revision:IsA("NumberValue"), "Player data revision is not available: " .. key)
	if value == nil then
		if item then
			item:Destroy()
		end
		topology = true
	elseif counts then
		local collection: Instance = item or Instance.new("Folder")
		if not item then
			collection.Name = key
			topology = true
		end
		for _, member in collection:GetChildren() do
			if counts[member.Name] == nil then
				member:Destroy()
				topology = true
			end
		end
		for name, count in counts do
			local member = collection:FindFirstChild(name)
			if member and member:IsA("NumberValue") then
				member.Value = count
			else
				local created = Instance.new("NumberValue")
				created.Name = name
				created.Value = count
				created.Parent = collection
				topology = true
			end
		end
		collection.Parent = group
	elseif item and item:IsA("BoolValue") and type(value) == "boolean" then
		item.Value = value
	elseif item and item:IsA("NumberValue") and type(value) == "number" then
		item.Value = value
	elseif item and item:IsA("StringValue") and type(value) == "string" then
		item.Value = value
	else
		if item then
			item:Destroy()
		end
		local created = CreateScalar(key, value)
		created.Parent = group
		topology = true
	end
	revision.Value += 1
	local record = Records[player]
	if record then record.Inventories[key] = nil; if topology or key == "DataLoaded" then record.Ready = nil end end
	local field = Schema.Fields[key]
	if (not field or field.Visibility ~= "Server") and (topology or key == "DataLoaded") then
		SchedulePublication(player)
	end
	return true
end

local function CheckReady(player: Player)
	if IsServer then
		return Records[player] ~= nil
	end
	local container = Container(player)
	local metadata = Metadata(player)
	local marker = if metadata then metadata:FindFirstChild("PublishedFields") else nil
	if not container or not marker or not marker:IsA("StringValue") or marker.Value == "" then
		return false
	end
	local success, decoded = pcall(function(): unknown
		return HttpService:JSONDecode(marker.Value)
	end)
	if not success or type(decoded) ~= "table" then
		return false
	end
	for _, name in Schema.Groups do
		local group = container:FindFirstChild(name)
		if not group or not group:IsA("Folder") then
			return false
		end
	end
	for key, rawDescriptor in pairs(decoded :: { [unknown]: unknown }) do
		if type(key) ~= "string" or type(rawDescriptor) ~= "table" then
			return false
		end
		local descriptor = rawDescriptor :: { [string]: unknown }
		local kind = descriptor.Kind
		if kind ~= "BoolValue" and kind ~= "NumberValue" and kind ~= "StringValue" and kind ~= "Folder" then
			return false
		end
		local item = Field(player, key)
		if not item or item.ClassName ~= kind then
			return false
		end
		if kind == "Folder" then
			if not InventoryValues.Contains(key) or type(descriptor.Members) ~= "table" then
				return false
			end
			for _, name in pairs(descriptor.Members :: { [unknown]: unknown }) do
				if type(name) ~= "string" then
					return false
				end
				local member = item:FindFirstChild(name)
				if not member or not member:IsA("NumberValue") then
					return false
				end
			end
		end
	end
	return true
end

function Values.IsReady(player)
	local record = Records[player]
	if not record then return false end
	if record.Ready == nil then record.Ready = CheckReady(player) end
	return record.Ready == true
end

function Values.Revision(player, key)
	local metadata = Metadata(player, key)
	local revisions = if metadata then metadata:FindFirstChild("Revisions") else nil
	local revision = if revisions then revisions:FindFirstChild(key) else nil
	return if revision and revision:IsA("NumberValue") then revision.Value else 0
end

function Values.Remove(player)
	local record = Records[player]
	if not record then
		return
	end
	Records[player] = nil
	if record.Private then record.Private:Destroy() end
	table.clear(record.Inventories)
	for _, connection in record.Connections do
		connection:Disconnect()
	end
	for _, watch in record.Watched do
		watch.Connection:Disconnect()
	end
	if IsServer then
		local container = Container(player)
		if container then
			container:Destroy()
		end
	end
end

return Values
