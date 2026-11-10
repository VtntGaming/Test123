local LeagueUtil = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LeagueConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("LeagueConfig"))
local Leagues = LeagueConfig.Leagues

function LeagueUtil.GetLeagueIndex(trophies)
	trophies = math.max(0, trophies or 0)
	for i = #Leagues, 1, -1 do
		if trophies >= Leagues[i].MinTrophies then return i end
	end
	return 1
end

function LeagueUtil.GetLeague(trophies)
	return Leagues[LeagueUtil.GetLeagueIndex(trophies)]
end

-- progress 0..1 toward next league, current floor, next threshold (nil in Champions)
function LeagueUtil.GetProgress(trophies)
	local i = LeagueUtil.GetLeagueIndex(trophies)
	local floor, nextLeague = Leagues[i].MinTrophies, Leagues[i + 1]
	if not nextLeague then return 1, floor, nil end
	return math.clamp((trophies - floor) / (nextLeague.MinTrophies - floor), 0, 1), floor, nextLeague.MinTrophies
end

function LeagueUtil.FormatNumber(n) -- 38699 → "38,699"
	local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

return LeagueUtil