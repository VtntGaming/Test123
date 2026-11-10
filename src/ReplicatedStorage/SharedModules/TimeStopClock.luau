-- TimeStopClock (SHARED ModuleScript) -> ReplicatedStorage.SharedModules.TimeStopClock
-- Remembers WHEN time was stopped, on the server and on every client (each side has its own copy, fed by the same
-- server timestamps). Anything that moves along a timeline (the thrown weapon) asks:
--     elapsed = now - startTime - Clock.Paused(startTime, now)
-- and therefore hangs in the air while time is stopped and continues afterwards.

local Clock = {}

local intervals = {} -- { { from = serverTime, to = serverTime | nil } }

function Clock.Begin(serverTime)
	local last = intervals[#intervals]
	if last and not last.to then return end -- already stopped
	table.insert(intervals, { from = serverTime })
	while #intervals > 20 do table.remove(intervals, 1) end
end

function Clock.End(serverTime)
	local last = intervals[#intervals]
	if last and not last.to then last.to = serverTime end
end

function Clock.IsStopped()
	local last = intervals[#intervals]
	return last ~= nil and last.to == nil
end

function Clock.StoppedSince()
	local last = intervals[#intervals]
	if last and not last.to then return last.from end
	return nil
end

-- seconds of [a, b] during which time was stopped
function Clock.Paused(a, b)
	local total = 0
	for _, interval in intervals do
		local from = math.max(interval.from, a)
		local to = math.min(interval.to or b, b)
		if to > from then total += to - from end
	end
	return total
end

function Clock.Reset()
	table.clear(intervals)
end

return Clock