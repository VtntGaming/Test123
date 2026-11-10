-- Owner-scoped instance reuse. Destroy the pool when its arena/owner is detached.
-- Acquire returns instance, optional factory data, lease. Always pass the lease to delayed cleanup.
local ObjectPool = {}
ObjectPool.__index = ObjectPool

local function cancelExpiry(entry)
	if entry.timer then
		task.cancel(entry.timer)
		entry.timer = nil
	end
end

function ObjectPool.new(options)
	assert(type(options.Create) == "function", "ObjectPool requires Create")
	local limit = options.MaxIdle or 16
	assert(
		type(limit) == "number" and limit >= 0 and limit < math.huge and limit % 1 == 0,
		"Invalid ObjectPool.MaxIdle"
	)
	return setmetatable(
		{ options = options, limit = limit, entries = {}, idle = {}, serial = 0, created = 0, reused = 0 },
		ObjectPool
	)
end

function ObjectPool:_storage()
	if not self.storage then
		self.storage = Instance.new("Folder")
		self.storage.Name = "ObjectPool_" .. (self.options.Name or "Instances")
		-- Keep idle hierarchies outside the DataModel: no rendering/physics or expensive replication-tree insertion.
	end
	return self.storage
end

function ObjectPool:_destroy(entry)
	self.entries[entry.instance] = nil
	cancelExpiry(entry)
	entry.connection:Disconnect()
	entry.instance:Destroy()
end

function ObjectPool:Acquire()
	assert(not self.destroyed, "ObjectPool is destroyed")
	local entry
	while #self.idle > 0 do
		local candidate = table.remove(self.idle)
		if self.entries[candidate.instance] == candidate and candidate.instance.Parent == self.storage then
			local ok = pcall(function()
				candidate.instance.Parent = nil
			end)
			if ok then
				entry = candidate
				break
			else
				self:_destroy(candidate)
			end
		elseif self.entries[candidate.instance] == candidate then
			self:_destroy(candidate)
		end
	end
	if entry then
		self.reused += 1
	else
		local instance, data = self.options.Create()
		if not instance then
			return nil
		end
		entry = { instance = instance, data = data }
		self.entries[instance] = entry
		entry.connection = instance.Destroying:Connect(function()
			self.entries[instance] = nil
			cancelExpiry(entry)
			entry.connection:Disconnect()
		end)
		self.created += 1
	end
	self.serial += 1
	entry.lease, entry.active = self.serial, true
	return entry.instance, entry.data, entry.lease
end

function ObjectPool:Release(instance, lease)
	local entry = self.entries[instance]
	if self.destroyed or not entry or not entry.active or entry.lease ~= lease then
		return false
	end
	entry.active = false
	cancelExpiry(entry)
	-- Hide before resetting geometry, particles or sounds so reset never appears in the scene.
	local detached = pcall(function()
		instance.Parent = nil
	end)
	if not detached then
		self:_destroy(entry)
		return true
	end
	if #self.idle >= self.limit then
		self:_destroy(entry)
		return true
	end
	if self.options.Reset then
		local ok, reusable = pcall(self.options.Reset, instance, entry.data)
		if not ok or reusable == false then
			self:_destroy(entry)
			if not ok then
				warn("[ObjectPool] Reset failed; instance discarded:", reusable)
			end
			return true
		end
	end
	local cached = pcall(function()
		instance.Parent = self:_storage()
	end)
	if not cached then
		self:_destroy(entry)
		return true
	end
	table.insert(self.idle, entry)
	return true
end

function ObjectPool:ReleaseAfter(instance, lease, seconds)
	-- Release checks the lease, so old expiry callbacks cannot touch a subsequent checkout.
	local entry = self.entries[instance]
	if not entry or not entry.active or entry.lease ~= lease then
		return false
	end
	cancelExpiry(entry)
	entry.timer = task.delay(seconds, function()
		entry.timer = nil
		self:Release(instance, lease)
	end)
	return true
end

function ObjectPool:GetStats()
	local active, idle = 0, 0
	for _, entry in self.entries do
		if entry.active then
			active += 1
		else
			idle += 1
		end
	end
	return { active = active, idle = idle, created = self.created, reused = self.reused }
end

function ObjectPool:Destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	for _, entry in self.entries do
		self:_destroy(entry)
	end
	table.clear(self.idle)
	if self.storage then
		self.storage:Destroy()
		self.storage = nil
	end
	self.options = nil
end

local function snapshot(instance)
	local records, objects = {}, instance:GetDescendants()
	table.insert(objects, 1, instance)
	for _, object in objects do
		local properties = {}
		if object:IsA("BasePart") then
			for _, name in
				{
					"CFrame",
					"Size",
					"PivotOffset",
					"Transparency",
					"Color",
					"Material",
					"Anchored",
					"CanCollide",
					"CanTouch",
					"CanQuery",
					"CastShadow",
				}
			do
				properties[name] = object[name]
			end
		elseif object:IsA("ParticleEmitter") then
			for _, name in
				{ "Enabled", "Rate", "TimeScale", "Speed", "Transparency", "Shape", "ShapeStyle", "LockedToPart" }
			do
				properties[name] = object[name]
			end
		elseif object:IsA("Beam") or object:IsA("Trail") then
			properties.Enabled, properties.Transparency = object.Enabled, object.Transparency
		elseif object:IsA("Decal") or object:IsA("Texture") then
			properties.Transparency = object.Transparency
		elseif object:IsA("Sound") then
			properties.Volume, properties.PlaybackSpeed = object.Volume, object.PlaybackSpeed
		elseif object:IsA("Light") then
			properties.Enabled, properties.Brightness = object.Enabled, object.Brightness
		end
		table.insert(records, { instance = object, properties = properties })
	end
	return {
		records = records,
		count = #objects - 1,
		pivot = if instance:IsA("PVInstance") then instance:GetPivot() else nil,
		scale = if instance:IsA("Model") then instance:GetScale() else nil,
	}
end

local function restore(instance, data)
	-- Modified hierarchies are discarded instead of lending incomplete models to the next spawn.
	if #instance:GetDescendants() ~= data.count then
		return false
	end
	for _, record in data.records do
		if record.instance ~= instance and not record.instance:IsDescendantOf(instance) then
			return false
		end
	end
	if data.scale and instance:GetScale() ~= data.scale then
		instance:ScaleTo(data.scale)
	end
	if data.pivot then
		instance:PivotTo(data.pivot)
	end
	for _, record in data.records do
		local object = record.instance
		if object:IsA("ParticleEmitter") or object:IsA("Trail") then
			object:Clear()
		end
		if object:IsA("Sound") then
			object.PlayOnRemove = false
			object:Stop()
			object.TimePosition = 0
		end
		for name, value in record.properties do
			if object[name] ~= value then
				object[name] = value
			end
		end
	end
	return true
end

-- Captures authored state once per clone; restores only on return, never in the movement loop.
function ObjectPool.fromTemplate(template, options)
	options = options or {}
	return ObjectPool.new({
		Name = options.Name or template.Name,
		MaxIdle = options.MaxIdle,
		Create = function()
			local instance = template:Clone()
			if not instance then
				return nil
			end
			return instance, snapshot(instance)
		end,
		Reset = restore,
	})
end

return ObjectPool
