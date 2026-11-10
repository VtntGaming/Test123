--!strict
-- Adds bounded subframe time to the synchronized simulation clock for visuals only.
-- Rollback changes the anchor; no local clock value feeds back into gameplay.

--// Properties
local Sample = time()
local ObservedAt = os.clock()

--// Types
export type Clock = { Now: () -> number }

--// Controller
local Clock: Clock = {} :: Clock

--// APIs
function Clock.Now()
	local now, wall = time(), os.clock()
	if now ~= Sample then
		Sample, ObservedAt = now, wall
	end
	return Sample + math.clamp(wall - ObservedAt, 0, 1 / 60)
end

return Clock
