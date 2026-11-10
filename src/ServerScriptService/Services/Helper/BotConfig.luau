-- BotConfig
-- Settings + roster of the "fake players" (bots) that fill the arena when only ONE real player is playing.
-- Server only (lives in ServerScriptService.Services.Helper, so it is NOT auto-required as a service).

local BotConfig = {
	Enabled = true,
	-- ★ TOTAL BOT POPULATION (change it here) ★
	-- Bots + real players = MaxBots: every real player on the server removes one bot
	-- 0 players = MaxBots, 1 player = MaxBots - 1, 2 players = MaxBots - 2 ... (a leaving player brings a bot back).
	-- Used by LobbyNPCService (it spawns / removes the lobby bots). Bots that are fighting in the arena count too.
	MaxBots = 10,
	BotsWhenSolo = 6, -- must stay > 0 for solo matches to use bots (0 = no bots). Fallback when BotsMin/BotsMax are missing.
	BotsMin = 3, -- random bot amount per round: between BotsMin and BotsMax (never the same number twice in a row)
	BotsMax = 6, -- MatchService caps the amount at 6
	LobbyBotsMin = 2, -- lobby bots (the normal case): random amount sent to the arena each round, the rest stay in the lobby
	LobbyBotsMax = 10, -- keep <= MaxBots (LobbyNPCService also clamps it to the bots that are really available)
	RespawnGrace = 1.2, -- seconds a bot may stay below the void line before BotService brings it back to the arena
	VIPChance = 0.25, -- 0..1 chance a bot shows the VIP tag above its head (a profile can force it with VIP = true/false)

	-- ===== human-like behaviour =====
	ReactionMin = 0.25, -- seconds an enemy must stay in reach before the bot reacts
	ReactionMax = 0.65,
	ChargeMin = 0.3, -- seconds the bot "holds" its swing (like a player charging M1)
	ChargeMax = 1.1,
	PauseChance = 0.35, -- chance to stand still for a moment after reaching a wander point
	PauseMin = 0.4,
	PauseMax = 2.0,
	MinAbilityCooldown = 8, -- bots never use their ability faster than this (AbilityConfig cooldowns are tiny for testing)
	DefaultAggression = 0.6, -- 0..1 chance the bot decides to hit an enemy that is within reach

	-- ===== lobby training =====
	-- Lobby bots that are waiting for the next match sometimes walk to the Training Area and practise like real players:
	-- they hit the dummy punching bag (tag TrainingBag) or the trainer / noob NPC (tag TraningNPC) with their own weapon.
	TrainingEnabled = true,
	TrainingChance = 0.5, -- chance, each time a lobby bot picks its next activity, that it goes training instead of wandering
	TrainingMaxBots = 4, -- at most this many bots train at the same moment
	TrainingMaxPerTarget = 2, -- ...and at most this many on the same target (the bag / the trainer NPC)
	TrainingMin = 8, -- seconds a bot keeps hitting once it arrived
	TrainingMax = 18,
	TrainingSwingGapMin = 0.3, -- extra pause between two swings (the weapon cooldown is always respected too)
	TrainingSwingGapMax = 1.2,
	TrainingWalkTimeout = 25, -- seconds a bot may take to reach the target before it gives up and goes back to wandering

	-- ===== smarter fighting =====
	DodgeSkill = 0.65, -- 0..1 chance the bot reacts to an incoming swing / rush (1 = never gets hit by what it sees)
	DodgeReactMin = 0.12, -- seconds before it reacts to the threat (human reaction time)
	DodgeReactMax = 0.32,
	DoubleJumpChance = 0.5, -- chance to follow a jump with a double jump (hops, dodges, stuck recovery)
	ApproachChance = 0.5, -- x aggression: chance a bot walks up to an enemy that is within ApproachRange
	ApproachRange = 24, -- studs; beyond this the bot just wanders (it never hunts across the whole map)
	RetreatWhenLives = 1, -- at or below this many lives a bot sometimes backs away from a close enemy

	-- ===== hunting / target choice =====
	HuntRange = 90, -- studs: bots look for enemies this far away (covers a whole arena) and walk up to them
	PursueChance = 1.15, -- x aggression: chance a bot decides to go after its target (roles add / remove a bit)
	PursueMin = 3, -- seconds a bot keeps pushing towards a target before it re-thinks
	PursueMax = 7,
	PlayerBias = 18, -- target score bonus (studs) for real players, so bots actually care about them
	TargetCrowdPenalty = 14, -- target score penalty (studs) per OTHER bot already hunting the same enemy
	TargetSwitchMargin = 10, -- stickiness: a bot keeps its target unless another is this much better
	RoleWeights = { Hunter = 0.35, Flanker = 0.30, Opportunist = 0.20, Skirmisher = 0.15 }, -- random fighting style per bot
	RoleRerollMin = 25, -- seconds before a bot may change its fighting style
	RoleRerollMax = 45,

	-- ===== navigation =====
	MaxPathComputes = 2, -- PathfindingService requests running at the same time (all bots together)
	RepathMin = 1.0, -- a bot waits at least this long (random up to RepathMax) before asking for a new path
	RepathMax = 1.8,
	RepathGoalDistance = 10, -- ...and only when its goal moved more than this since the last path

	-- ===== spawning =====
	SpawnMinSpacing = 14, -- studs between two bots at spawn
	DropHeight = 20, -- bots drop in like players do (keep equal to MatchService ARENA_DROP_HEIGHT / ARENA_DROP_TIME)
	DropTime = 1,

	-- abilities the bot AI knows how to use (implemented in BotService)
	SupportedAbilities = { 
		"Dash", 
		"MegaJump",
		"Push", 
		"Pull", 
		"Charge", 
		"Shield" 
	},

	-- ===== roster =====
	-- Name        = display name above the head (must be unique, a number is added if a real player has the same name)
	-- Weapon      = base weapon id from WeaponConfig.BaseWeapons (Slap / Bat / Hammer / Stick / Chicken)
	-- WeaponSkin  = optional variant model from ReplicatedStorage.Assets.Weapons (e.g. "BatKing", "HammerFire")
	-- Ability     = one of SupportedAbilities (nil = random)
	-- Aggression  = optional override of DefaultAggression
	-- VIP         = optional true/false: force the VIP tag on/off (nil = random using VIPChance)
	-- UserId      = optional: copy the avatar (hair, clothes, face, colors) of this Roblox user
	-- Look        = optional HumanoidDescription properties to override, for example:
	--               { Shirt = 123456, Pants = 123456, HatAccessory = "123,456", Face = 123456,
	--                 HeadColor = Color3.fromRGB(...), TorsoColor = ..., LeftArmColor = ..., RightArmColor = ...,
	--                 LeftLegColor = ..., RightLegColor = ... }
	--               If neither UserId nor Look is given, a random skin tone + random outfit colors are used.
	Profiles = {
		{ Name = "Axicivi", Weapon = "Slap", WeaponSkin = "SlapFire", Ability = "Dash", UserId = 265581589, Aggression = 0.7 },
		{ Name = "LunaPlays_07", Weapon = "Bat", WeaponSkin = "BatSamourai", Ability = "Shield", Aggression = 0.5 },
		{ Name = "Noah_2012", Weapon = "Stick", WeaponSkin = "StickLightning", Ability = "Push", Aggression = 0.65 },
		{ Name = "ItzRyuu", Weapon = "Hammer", WeaponSkin = "HammerDemon", Ability = "Charge", Aggression = 0.75 },
		{ Name = "BlockMaster99", Weapon = "Chicken", WeaponSkin = "ChickenKing", Ability = "MegaJump", Aggression = 0.55 },
		{ Name = "SkyyRoblox", Weapon = "Slap", WeaponSkin = "SlapDiamond", Ability = "Pull", Aggression = 0.6 },
		{ Name = "TheRealMilo", Weapon = "Bat", WeaponSkin = "BatKing", Ability = "Dash", Aggression = 0.8 },
		{ Name = "Aria_x3", Weapon = "Stick", WeaponSkin = "StickMagical", Ability = "Shield", Aggression = 0.45 },
		{ Name = "DarkLord_YT", Weapon = "Hammer", WeaponSkin = "HammerCelestial", Ability = "Push", Aggression = 0.7 },
		{ Name = "Pixel_Fox", Weapon = "Chicken", WeaponSkin = "ChickenLightning", Ability = "Charge", Aggression = 0.6 },
		{ Name = "EmberStorm", Weapon = "Slap", WeaponSkin = "SlapIce", Ability = "MegaJump", Aggression = 0.5 },
		{ Name = "Jaxon_Pro", Weapon = "Bat", WeaponSkin = "BatDiamond", Ability = "Pull", Aggression = 0.65 },
	},
}

return BotConfig
