--!strict
-- Builds a lifetime playtime funnel capturing specific time milestones.

local PlaytimeFunnel = {}

-- v2: step 1 is now "Joined" (0s), so every player who loads in enters the funnel.
-- Bumped from v1 because adding a step shifts all step numbers.
local FUNNEL_NAME = "PlaytimeLifetime_v2"

-- Define your milestones in seconds
local MILESTONES = {
	0,     -- Joined (step 1, fired as soon as player data loads)
	30,    -- 30s
	60,    -- 1m
	120,   -- 2m
	180,   -- 3m
	300,   -- 5m
	600,   -- 10m
	1800,  -- 30m
	3600,  -- 1h
}

-- Returns the highest milestone index achieved
local function getStepForPlaytime(playtime)
	local step = 0
	for i, milestone in ipairs(MILESTONES) do
		if playtime >= milestone then
			step = i
		else
			break
		end
	end
	return step
end

local function buildEvent(step)
	local seconds = MILESTONES[step]
	local stepName
	if seconds == 0 then
		stepName = "Joined"
	elseif seconds >= 60 then
		stepName = "Played_" .. tostring(seconds / 60) .. "m"
	else
		stepName = "Played_" .. tostring(seconds) .. "s"
	end

	return {
		kind = "Funnel",
		name = FUNNEL_NAME,
		step = step,
		stepName = stepName,
	}
end

function PlaytimeFunnel.NewSession(playtime)
	return {
		lastMilestoneStep = getStepForPlaytime(playtime or 0),
		playtime = playtime or 0,
	}
end

-- Fires step 1 (Joined) for every player when their data loads, then restores
-- a returning player's latest milestone into the lifetime funnel.
function PlaytimeFunnel.DataReady(session)
	local events = { buildEvent(1) }
	if session.lastMilestoneStep > 1 then
		table.insert(events, buildEvent(session.lastMilestoneStep))
	end
	return events
end

-- Advances playtime and generates events for newly crossed milestones.
function PlaytimeFunnel.RecordPlaytime(session, playtime)
	session.playtime = playtime
	local currentStep = getStepForPlaytime(playtime)

	if currentStep > session.lastMilestoneStep then
		local events = {}
		-- Catch up on any skipped steps
		for step = session.lastMilestoneStep + 1, currentStep do
			table.insert(events, buildEvent(step))
		end
		session.lastMilestoneStep = currentStep
		return events
	end
	return nil
end

return PlaytimeFunnel
