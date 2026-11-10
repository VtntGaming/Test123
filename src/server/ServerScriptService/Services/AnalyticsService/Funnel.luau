-- Builds lifetime-progression events; the parent service owns their submission.
local Funnel = {}

-- Use a new name so historical per-visit data does not mix with lifetime totals.
local FUNNEL_NAME = "GamesPlayedLifetime"
local MAX_FUNNEL_STEPS = 100

local function matchEvent(gamesPlayed)
	return {
		kind = "Funnel",
		name = FUNNEL_NAME,
		-- No session ID: this is a one-time funnel per player, across all visits.
		step = gamesPlayed,
		stepName = "Game " .. tostring(gamesPlayed),
	}
end

-- GamesPlayed is loaded/saved by PlayerDataService and advanced by MatchService.
-- The in-memory value only prevents duplicate progression within this visit.
function Funnel.NewSession(gamesPlayed)
	return {
		gamesPlayed = gamesPlayed or 0,
	}
end

-- Restore existing players' latest milestone into the lifetime funnel.
-- Roblox considers earlier skipped steps complete and ignores repeated steps.
-- Game 1 is step 1, leaving all 100 steps available for games (no baseline).
function Funnel.DataReady(session)
	if session.gamesPlayed < 1 then return nil end
	return matchEvent(math.min(session.gamesPlayed, MAX_FUNNEL_STEPS))
end

-- Use the saved lifetime total, never a counter that resets on rejoin.
-- The parent still submits a custom participation event after game 100.
function Funnel.RecordMatch(session, gamesPlayed)
	if gamesPlayed <= session.gamesPlayed then return nil end
	session.gamesPlayed = gamesPlayed
	if gamesPlayed > MAX_FUNNEL_STEPS then return nil end
	return matchEvent(gamesPlayed)
end

return Funnel
