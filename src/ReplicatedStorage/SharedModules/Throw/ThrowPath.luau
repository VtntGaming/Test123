-- ThrowPath (SHARED ModuleScript) -> ReplicatedStorage.SharedModules.ThrowPath
-- The flight of the thrown weapon as a pure function of time, so the SERVER (hit detection) and every CLIENT (visual)
-- compute exactly the same path from the same few numbers.
--   OUT     flies away along `forward`, decelerating, bulging to the right (Jedi saber arc)
--   HOVER   spins on the spot at the end point for a moment
--   RETURN  flies back to the thrower's hand (tracks the hand, accelerates), bulging to the LEFT -> an oval loop

local ThrowPath = {}
ThrowPath.__index = ThrowPath

-- p = { origin, forward, range, curve, outTime, hoverTime, returnTime, [startTime], [weaponName] }
function ThrowPath.new(p)
	local self = setmetatable({}, ThrowPath)
	self.origin = p.origin
	self.forward = p.forward
	self.side = p.forward:Cross(Vector3.yAxis).Unit -- the thrower's right
	self.range = p.range
	self.curve = p.curve
	self.outTime = p.outTime
	self.hoverTime = p.hoverTime
	self.returnTime = p.returnTime
	self.startTime = p.startTime
	self.weaponName = p.weaponName
	self.endPoint = p.origin + p.forward * p.range
	self.total = p.outTime + p.hoverTime + p.returnTime
	return self
end

-- the table that is sent to the clients
function ThrowPath:Params(startTime, weaponName)
	return {
		origin = self.origin, forward = self.forward, range = self.range, curve = self.curve,
		outTime = self.outTime, hoverTime = self.hoverTime, returnTime = self.returnTime,
		startTime = startTime, weaponName = weaponName,
	}
end

-- t = seconds since the weapon left the hand, hand = where the thrower's hand is RIGHT NOW (return target)
-- returns position, phase   (phase = "Wait" | "Out" | "Hover" | "Return" | "Done")
function ThrowPath:At(t, hand)
	if t < 0 then
		return self.origin, "Wait"
	end
	if t < self.outTime then
		local a = t / self.outTime
		local eased = 1 - (1 - a) ^ 2 -- fast start, slows down
		return self.origin + self.forward * (self.range * eased) + self.side * (self.curve * math.sin(math.pi * a)), "Out"
	end
	t -= self.outTime
	if t < self.hoverTime then
		return self.endPoint + Vector3.new(0, math.sin(t * 9) * 0.6, 0), "Hover"
	end
	t -= self.hoverTime
	if t < self.returnTime then
		local b = t / self.returnTime
		local eased = b * b -- slow start, snaps back into the hand
		return self.endPoint:Lerp(hand, eased) - self.side * (self.curve * math.sin(math.pi * b)), "Return"
	end
	return hand, "Done"
end

return ThrowPath