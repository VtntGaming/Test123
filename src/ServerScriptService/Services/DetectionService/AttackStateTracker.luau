-- Bounded recent state evidence and asynchronous checks; no combat decisions or punishments.
local Tracker = {}
Tracker.__index = Tracker

function Tracker.new(settings)
	return setmetatable({ settings = settings, pending = {} }, Tracker)
end

function Tracker:Reset()
	table.clear(self.pending)
	self.actor, self.lastSampleAt, self.lastAirborneAt, self.lastGroundedAt = nil, nil, nil, nil
end

function Tracker:Observe(actor, airborne, now)
	if
		self.actor ~= actor
		or type(airborne) ~= "boolean"
		or (self.lastSampleAt and (now < self.lastSampleAt or now - self.lastSampleAt > self.settings.MaxSampleGap))
	then
		-- Missing samples, respawns and interrupted movement make outstanding checks inconclusive.
		self:Reset()
	end
	self.actor = actor
	if type(airborne) ~= "boolean" then
		return {}
	end
	self.lastSampleAt = now
	if airborne then
		self.lastAirborneAt = now
	else
		self.lastGroundedAt = now
	end
	local reports = {}
	for index = #self.pending, 1, -1 do
		local check = self.pending[index]
		if airborne == check.airborne then
			-- Include the first sample at the deadline, allowing for the sampler's frame boundary.
			table.remove(self.pending, index)
		elseif now >= check.deadline then
			table.remove(self.pending, index)
			check.lastAirborneAt, check.lastGroundedAt = self.lastAirborneAt, self.lastGroundedAt
			table.insert(reports, check)
		end
	end
	return reports
end

function Tracker:Track(attackId, attackType, clientStartedAt, now, ping)
	if not self.lastSampleAt then
		return false
	end
	local airborne = attackType == "JumpAttack"
	local evidenceAt = if airborne then self.lastAirborneAt else self.lastGroundedAt
	if evidenceAt and evidenceAt >= now - self.settings.HistoryWindow then
		return false
	end
	if #self.pending >= self.settings.MaxPending then
		-- Never turn overload into evidence against the player.
		table.remove(self.pending, 1)
	end
	table.insert(self.pending, {
		attackId = attackId,
		attackType = attackType,
		airborne = airborne,
		clientStartedAt = clientStartedAt,
		receivedAt = now,
		deadline = now + self.settings.ObservationWindow,
		ping = ping,
	})
	return true
end

return Tracker
