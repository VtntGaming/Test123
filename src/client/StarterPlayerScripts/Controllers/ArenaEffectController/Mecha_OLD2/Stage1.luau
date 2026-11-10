-- Straight conveyor movement; entry is driven by each neighboring pair's bounding-box gap.
local Stage1 = {}
local Config = require(script.Parent.Config)
local MotionMath = require(script.Parent.MotionMath)
local eased, interpolate, window = MotionMath.Eased, MotionMath.Interpolate, MotionMath.Window

function Stage1.EndFraction(self)
	return if Config.Stage2.Enable then Config.Stage2.StartFraction else 1
end

function Stage1.Capacity(self, side)
	local capacity = math.floor(Config.Stage1.MaxActive / #self.paths)
	return capacity + (if side <= Config.Stage1.MaxActive % #self.paths then 1 else 0)
end

local function separation(previous, nextStructure)
	-- Compare the leading model's rear edge with the following model's front edge, including pivot offsets.
	return math.max(0.001, nextStructure.frontOffset - previous.rearOffset + Config.Stage1.StructureSpacing)
end

function Stage1.Update(self, elapsed, total)
	local settings = Config.Stage1
	if #self.paths == 0 or #self.templates == 0 then
		return
	end
	local previous = self.travelElapsed or total * settings.StartFraction
	local delta = math.max(elapsed - previous, 0)
	local steps = math.clamp(math.ceil(delta / 0.05), 1, 2048)
	local step, distance = delta / steps, 0
	for index = 1, steps do
		local time = previous + (index - 0.5) * step
		local progress = eased(window(time, total, settings.StartFraction, self:_stage1EndFraction()), settings)
		distance += interpolate(settings.TravelSpeed, progress) * step
	end
	self.travelElapsed = elapsed
	self.travelDistance = (self.travelDistance or 0) + distance
	for _, path in self.paths do
		if path.lastExited then
			path.lastExited.pathDistance += distance
		end
		for slot = path.firstSlot or 0, path.nextSlot - 1 do
			local data = path.movingSlots[slot]
			if data then
				data.pathDistance += distance
				data.pathFraction = data.pathDistance / path.length
			end
		end
	end
	for index = #self.structures, 1, -1 do
		local data = self.structures[index]
		if not data.final and data.pathFraction >= 1 then
			local path = self.paths[data.side]
			if not path.lastExited or data.movingSlot > path.lastExited.slot then
				-- Keep only scheduling numbers, never a destroyed model's entire part cache.
				path.lastExited =
					{ slot = data.movingSlot, pathDistance = data.pathDistance, rearOffset = data.rearOffset }
			end
			self:_removeStructure(index)
		end
	end
	local remaining = settings.MaxSpawnsPerFrame
	for side, path in self.paths do
		local first = path.firstSlot or 0
		while first < path.nextSlot and not path.movingSlots[first] do
			first += 1
		end
		path.firstSlot = first
		local tailSlot = path.nextSlot - 1
		while tailSlot >= first and not path.movingSlots[tailSlot] do
			tailSlot -= 1
		end
		local tail = path.movingSlots[tailSlot]
		while (path.activeCount or 0) < self:_stage1Capacity(side) and remaining > 0 do
			path.pending = path.pending or self:_prepareStructure(side, settings)
			local candidate = path.pending
			if not candidate then
				break
			end
			local anchor = tail or path.lastExited
			local position = if anchor
				then math.min(path.length - 0.001, anchor.pathDistance - separation(anchor, candidate))
				elseif path.started then 0
				else math.min(path.length - 0.001, self.travelDistance)
			if position < 0 then
				break
			end
			remaining -= 1
			local data = self:_spawn(side, elapsed, settings, nil, nil, candidate)
			if not data then
				break
			end
			local slot = path.nextSlot
			data.movingSlot, data.pathDistance, data.pathFraction = slot, position, position / path.length
			path.movingSlots[slot] = data
			path.activeCount = (path.activeCount or 0) + 1
			path.nextSlot, path.pending, path.started = slot + 1, nil, true
			tail = data
		end
	end
end

function Stage1.Pose(data)
	local alpha = math.clamp(data.pathFraction, 0, 1)
	local size = data.startScale
	if data.settings.ScaleEnable then
		size = if alpha <= 0.5
			then data.startScale + (data.endScale - data.startScale) * (alpha * 2)
			else data.endScale + (data.finishScale - data.endScale) * ((alpha - 0.5) * 2)
	end
	local settings = data.settings.Transparency
	local fadeIn = eased(alpha / settings.FadeInEndFraction, settings)
	local fadeOut = eased((alpha - settings.FadeOutStartFraction) / (1 - settings.FadeOutStartFraction), settings)
	return alpha, size, math.max(1 - fadeIn, fadeOut)
end

function Stage1.IsActive(elapsed, total)
	return Config.Stage1.Enable
		and elapsed >= total * Config.Stage1.StartFraction
		and (not Config.Stage2.Enable or elapsed < total * Config.Stage2.StartFraction)
end

function Stage1.Reset(self)
	for _, path in self.paths do
		table.clear(path.movingSlots)
		path.firstSlot, path.nextSlot, path.activeCount = 0, 0, 0
		path.pending, path.started, path.lastExited = nil, nil, nil
	end
	self.travelElapsed, self.travelDistance = nil, nil
end

return Stage1
