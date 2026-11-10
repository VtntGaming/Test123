-- Conveyor movement, per-model spacing and stage 1 spawn scheduling.
local Stage1 = {}
local Config = require(script.Parent.Config)
local MotionMath = require(script.Parent.MotionMath)
local eased, interpolate, window = MotionMath.Eased, MotionMath.Interpolate, MotionMath.Window

function Stage1.EndFraction(self)
	return if Config.Stage2.Enable then Config.Stage2.StartFraction else 1
end

function Stage1.Spacing(self, path, side, elapsed, total)
	local settings = Config.Stage1
	local progress = eased(window(elapsed, total, settings.StartFraction, self:_stage1EndFraction()), settings)
	local count = settings.StructureCount.X + (settings.StructureCount.Y - settings.StructureCount.X) * progress
	local spacing = path.length / count
	return math.max(spacing, self:_stage1Padding(path) + 0.001, path.length / self:_stage1Capacity(side))
end

function Stage1.Capacity(self, side)
	local capacity = math.floor(Config.Stage1.MaxActive / #self.paths)
	return capacity + (if side <= Config.Stage1.MaxActive % #self.paths then 1 else 0)
end

function Stage1.Width(self, data, path)
	data.sizeFit = 1
	if Config.Stage1.FitToStructureCount then
		data.sizeFit = math.clamp(
			(path.spacing - Config.Stage1.SpacingPadding - data.floatWidth) / math.max(data.peakWidth, 0.001),
			0,
			1
		)
	end
	return math.max(data.peakWidth * data.sizeFit, data.minimumWidth) + data.floatWidth
end

local function movingStructures(path)
	local list = {}
	for _, data in path.movingSlots do
		table.insert(list, data)
	end
	table.sort(list, function(a, b)
		return a.movingSlot < b.movingSlot
	end)
	return list
end

local function separation(path, previous, nextStructure)
	return math.max(path.spacing, (previous.travelWidth + nextStructure.travelWidth) / 2 + Config.Stage1.SpacingPadding)
end

function Stage1.Padding(self, path)
	local direction = if path.start and path.finish then (path.finish - path.start).Unit else Vector3.zero
	return Config.Stage1.SpacingPadding + Config.Stage1.Floating.Amplitude.Max * 2 * math.abs(direction.Y)
end

function Stage1.Update(self, elapsed, total)
	local settings = Config.Stage1
	if #self.paths == 0 or #self.templates == 0 then
		return
	end
	local previous = self.travelElapsed or total * settings.StartFraction
	local delta = math.max(elapsed - previous, 0)
	local steps = math.clamp(math.ceil(delta / 0.05), 1, 2048)
	local step = delta / steps
	local distance = 0
	for i = 1, steps do
		local time = previous + (i - 0.5) * step
		local progress = eased(window(time, total, settings.StartFraction, self:_stage1EndFraction()), settings)
		local speed = interpolate(settings.TravelSpeed, progress)
		distance += speed * step
	end
	self.travelElapsed = elapsed
	self.travelDistance = (self.travelDistance or 0) + distance
	for side, path in self.paths do
		path.spacing = self:_stage1Spacing(path, side, elapsed, total)
		if path.lastExited then
			path.lastExited.pathDistance += distance
		end
		local previous
		for _, data in movingStructures(path) do
			data.travelWidth = self:_stage1Width(data, path)
			data.pathDistance = if previous
				then previous.pathDistance - separation(path, previous, data)
				else data.pathDistance + distance
			data.pathFraction = data.pathDistance / path.length
			previous = data
		end
	end
	for index = #self.structures, 1, -1 do
		local data = self.structures[index]
		if not data.final then
			if data.pathFraction >= 1 then
				local path = self.paths[data.side]
				if not path.lastExited or data.movingSlot > path.lastExited.movingSlot then
					path.lastExited = data
				end
				self:_removeStructure(index)
			end
		end
	end
	local remaining = settings.MaxSpawnsPerFrame
	for side, path in self.paths do
		local list = movingStructures(path)
		local tail = list[#list]
		for _ = #list + 1, self:_stage1Capacity(side) do
			if remaining <= 0 then
				return
			end
			path.pending = path.pending or self:_prepareStructure(side, settings)
			local candidate = path.pending
			if not candidate then
				break
			end
			candidate.travelWidth = self:_stage1Width(candidate, path)
			if not tail and path.lastExited then
				path.lastExited.travelWidth = self:_stage1Width(path.lastExited, path)
			end
			local position = if tail
				then tail.pathDistance - separation(path, tail, candidate)
				else (if path.lastExited
					then math.min(
						path.length - 0.001,
						path.lastExited.pathDistance - separation(path, path.lastExited, candidate)
					)
					elseif path.started then 0
					else math.min(
						path.length - 0.001,
						self.travelDistance - (side - 1) / #self.paths * path.spacing
					))
			if position < 0 then
				break -- Keep this candidate's own dimensions until there is room to enter.
			end
			local progress = window(elapsed, total, settings.StartFraction, self:_stage1EndFraction())
			local speed = interpolate(settings.TravelSpeed, eased(progress, settings))
			local born = math.max(total * settings.StartFraction, elapsed - position / speed)
			local data = self:_spawn(side, born, settings, nil, nil, candidate)
			remaining -= 1
			if not data then
				break
			end
			local slot = path.nextSlot or 0
			data.movingSlot, data.pathDistance, data.pathFraction = slot, position, position / path.length
			path.movingSlots[slot] = data
			path.nextSlot, path.pending, path.started = slot + 1, nil, true
			path.lastExited = nil
			tail = data
		end
	end
end

function Stage1.Pose(data)
	local alpha = math.clamp(data.pathFraction, 0, 1)
	-- The sampled FinalScale is reached halfway along the conveyor path.
	local size = if alpha <= 0.5
		then data.startScale + (data.endScale - data.startScale) * (alpha * 2)
		else data.endScale + (data.finishScale - data.endScale) * ((alpha - 0.5) * 2)
	local settings = data.settings.Transparency
	local pathFraction = alpha * data.stopFraction
	local fadeIn = eased(pathFraction / settings.FadeInEndFraction, settings)
	local fadeOut =
		eased((pathFraction - settings.FadeOutStartFraction) / (1 - settings.FadeOutStartFraction), settings)
	return alpha, size * data.sizeFit, math.max(1 - fadeIn, fadeOut)
end

function Stage1.IsActive(elapsed, total)
	return Config.Stage1.Enable
		and elapsed >= total * Config.Stage1.StartFraction
		and (not Config.Stage2.Enable or elapsed < total * Config.Stage2.StartFraction)
end

function Stage1.Reset(self)
	for _, path in self.paths do
		table.clear(path.movingSlots)
		path.nextSlot, path.pending, path.spacing, path.started, path.lastExited = 0, nil, nil, nil, nil
	end
	self.travelElapsed, self.travelDistance = nil, nil
end

return Stage1
