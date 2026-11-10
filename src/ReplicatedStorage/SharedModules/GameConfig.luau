-- Defines shared match, arena, movement, combat, and reward settings.
local GameConfig = {
	-- Match Settings
	MinPlayersToStart = 1,
	MinPlayersToStartStudio = 1,
	IntermissionTime = 5,	-- Additional time before the voting period
	PreparingTime = 3,
	VoteTime = 10,
	MatchTimeLimit = 180,
	NPCsToSpawn = 30,

	-- Map Settings
	LobbyName = "Lobby",
	ArenaName = "Arena",
	VoidHeight = 170,
	SkyHeight = 3000,
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
		HitboxLatencyCompensation = {
			Enable = true, -- Player-owned movement only; predicts both normal and jump attack hitboxes.
			MaxPredictionTime = 0.15, -- Seconds; prediction uses half the attacker's round-trip network ping.
			MaxOffset = 6, -- Studs; limits the total movement prediction, including jump/fall motion.
		},
	},

	-- Session-only suspicion signals; no automatic punishment.
	Detection = {
		AttackState = {
			Enable = true,
			HistoryWindow = 0.5, -- Seconds of recent server evidence before receiving Start.
			ObservationWindow = 0.5, -- Seconds to observe the requested state after receiving Start.
			SampleInterval = 0.05, -- Seconds between movement observations.
			MaxSampleGap = 0.2, -- Larger gaps make pending checks inconclusive.
			MaxPending = 16, -- Per-player bound; excess oldest checks are discarded without a report.
		},
		AttackStateMismatchWeight = 1,
		DecayPerSecond = 0.1, -- Suspicion points removed per second.
		FlagThreshold = 5, -- Sets the player's DetectionFlagged attribute; evidence for review, not proof.
		MaxReports = 20, -- Recent reports retained per player until they leave.
		WarnOnReport = true,
	},

	-- Arena Events Settings
	ArenaDestruction = {
		InitialDelay = 5, -- Secondi di attesa prima che inizi la distruzione
		-- English: Seconds to wait before destruction begins.
		WarningDuration = 2.5, -- Durata dell'avviso di tremolio
		-- English: Duration of the shaking warning.
		IntervalBetweenBlocks = 5, -- Secondi di pausa tra la distruzione di un modello e l'altro
		-- English: Seconds between the destruction of one model and the next.
		IntervalLastBlock = 20, -- Secondi tra l'ultimo blocco distrutto e la fine
		-- English: Seconds between the last block's destruction and the end.
	},

	ArenaShrink = {
		ServerUpdateInterval = 1, -- Seconds between Moon server collision updates.
		InitialDelay = 10, -- Secondi prima che inizi a rimpicciolirsi
		-- English: Seconds before it starts shrinking.
		--ShrinkTime = 100, -- Quanto tempo ci mette a raggiungere la dimensione minima
		-- English: How long it takes to reach the minimum size.
		MinScale = 0.01, -- Dimensione finale (es. 20% dell'originale)
		-- English: Final size (e.g., 20% of the original).
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
