-- Defines shared match, arena, movement, combat, and reward settings.
local GameConfig = {
	-- Match Settings
	MinPlayersToStart = 1,
	MinPlayersToStartStudio = 1,
	IntermissionTime = 20,	-- Additional time before the voting period
	PreparingTime = 10,
	VoteTime = 10,
	MatchTimeLimit = 180,
	NPCsToSpawn = 1,

	-- Map Settings
	LobbyName = "Lobby",
	ArenaName = "Arena",
	VoidHeight = 170,
	ArenaSpawnRadius = 15,
	ArenaBounds = {
		SizeOffset = Vector3.new(20, 150, 20), -- Added to the full bounding-box size.
		OutsideTimeout = 15, -- Continuous seconds outside before applying a void loss.
	},

	-- Movement Settings
	Movement = {
		WalkSpeed = 24,
		JumpHeight = 15,
		MaxWallJumps = 2,
	},

	-- Combat Settings
	Combat = {
		MaxHitDistance = 50,
		MaxChargeTime = 2.5,
		MinChargeMultiplier = 1,
		MaxChargeMultiplier = 2.5,
	},

	-- Session-only suspicion signals; no automatic punishment.
	Detection = {
		AttackStateMismatchWeight = 1,
		DecayPerSecond = 0.1, -- Suspicion points removed per second.
		FlagThreshold = 5, -- Sets the player's DetectionFlagged attribute; evidence for review, not proof.
		MaxReports = 20, -- Recent reports retained per player until they leave.
		WarnOnReport = true,
	},

	-- Arena Events Settings
	ArenaDestruction = {
		InitialDelay = 5, -- Secondi di attesa prima che inizi la distruzione
		WarningDuration = 2.5, -- Durata dell'avviso di tremolio
		IntervalBetweenBlocks = 5, -- Secondi di pausa tra la distruzione di un modello e l'altro
		IntervalLastBlock = 20, -- Secondi tra l'ultimo blocco distrutto e la fine
	},

	ArenaShrink = {
		-- Physical arena geometry advances at the shared fixed simulation frequency.
		InitialDelay = 10, -- Secondi prima che inizi a rimpicciolirsi
		--ShrinkTime = 100, -- Quanto tempo ci mette a raggiungere la dimensione minima
		MinScale = 0.01, -- Dimensione finale (es. 20% dell'originale)
	},

	ArenaFalling = {
		-- Read at startup: true = local visual copies; false = server-moved geometry.
		ClientVisuals = true,
		InitialDelay = 10,
		WarningDuration = 2.5,
		IntervalBetweenPlatforms = 15,
		IntervalLastPlatform = 20,
		DropDistance = 55,
		DropDuration = 3.0,
		FadeDelay = 0.5,
		ShakeSpeed = 18,
		ShakeIntensity = 0.15,
	},
	
	CoinRewards = {
		Placement = { 800, 350, 200, 150, 75, 25 },  -- 1st, 2nd, 3rd
		PlacementDefault = 50,          -- every other place up to PlacementDefaultMaxRank
		PlacementDefaultMaxRank = 10,   -- below this rank: 0 coins
		KillPlayer = 30,                -- per life knocked off a player
		KillNPC = 5,                    -- per life knocked off an arena NPC
		KillDripInterval = 0.1,         -- seconds between each coin of a kill reward
		ArenaKillsOnly = true,          -- no kill coins for knock-offs in the lobby
	},
}

return GameConfig
