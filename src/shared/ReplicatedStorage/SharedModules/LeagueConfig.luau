local LeagueConfig = {
	-- Ordered low → high. First league must start at 0.
	-- Win/Loss are per the player's CURRENT league (higher leagues = harder to climb).
	Leagues = {
		{ Name = "Bronze",    MinTrophies = 0,    Icon = "rbxassetid://94065471951439", Color = Color3.fromRGB(205, 127, 50),  Win = 30, Loss = 5  },
		{ Name = "Silver",    MinTrophies = 500,  Icon = "rbxassetid://92185043583832", Color = Color3.fromRGB(200, 200, 210), Win = 28, Loss = 10 },
		{ Name = "Gold",      MinTrophies = 1500, Icon = "rbxassetid://70972379977995", Color = Color3.fromRGB(255, 200, 40),  Win = 26, Loss = 15 },
		{ Name = "Master",    MinTrophies = 3000, Icon = "rbxassetid://77054206152105", Color = Color3.fromRGB(170, 90, 255),  Win = 24, Loss = 20 },
		{ Name = "Champions", MinTrophies = 5000, Icon = "rbxassetid://82733667124565", Color = Color3.fromRGB(255, 80, 80),   Win = 22, Loss = 24 },
	},

	-- Match rules
	DrawTrophies = 0,                 -- timer ran out with several players alive
	MinPlayersForTrophies = 7,        -- matches with fewer players are unranked (no gain, no loss)

	-- Placements that EARN trophies, as a multiplier of the league's Win value.
	-- 1st = 100% Win, 2nd = 60%, 3rd = 30%. Add/remove entries to change how many places are rewarded.
	PlacementWinScale = { 1, 0.7, 0.5 },

	-- Everyone below the rewarded places:
	LoseOutsideTop = true,            -- false = 4th and below get 0 instead of losing trophies
	LossScaleByPlacement = { Min = 0.5, Max = 1 }, -- 4th loses Min×Loss, last place Max×Loss
	PenalizeLeavers = true,           -- leaving during Starting/Playing = last place

	-- Leaderboard (server reads all of it, client reads DisplayDepth)
	Leaderboard = {
		OrderedStoreName  = "TrophiesLeaderboard_V1",
		SnapshotStoreName = "TrophiesSnapshot_V1",
		BuildMapName      = "RanksBuild_V1",      -- MemoryStore HashMap: State + Build_<seq>
		JobQueueName      = "RanksBuildJobs_V1",  -- MemoryStore Queue

		DisplayDepth   = 10000,   -- rows with names, shown in the list
		RankDepth      = 100000,  -- personal rank computed down to here; deeper → "100,000+"
		DisplayMargin  = 0.1,     -- name rows cover DisplayDepth × 1.1 to absorb drift

		RowsShardSize  = 1000,    -- 10 GetSortedAsync pages, names resolved
		CountShardSize = 5000,    -- 50 pages, histogram only (no ids, no names)
		ShardCapMultiplier = 2,   -- a planned shard that grows past size×2 splits itself

		BuildInterval  = 15 * 60, -- from last commit to next build
		BuildTimeout   = 45 * 60, -- a Running build older than this is abandoned
		JobLease       = 5 * 60,  -- queue invisibility timeout + claim lease
		MinListBudget  = 10,      -- only take a job if ~10 pages are affordable now
		ReadInterval   = 120,     -- reader fallback poll (commit is also pushed)
		StoreNames     = true,    -- mockup rows show no name; false = skip UserService entirely
		ChunkSize      = 50,      -- client page size
	},
}

return LeagueConfig