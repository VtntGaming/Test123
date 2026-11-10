-- Defines ability presentation, rarity, prices, and gameplay settings.
local AbilityConfig = {}

-- ==========================================
-- ABILITIES DATA
-- ==========================================
export type AbilityConfig = {
	Order: number?,
	Unlisted: boolean?,
	Icon: string?,
	Rarity: string?,
	Price: {
		Price: number,	-- Show as product id if robux
		IsRobux: boolean?,
	}?
}
local Rarity = {
	Common = "Common",
	Rare = "Rare",
	Epic = "Epic",
	Legendary = "Legendary",
	Mythic = "Mythic"
}
AbilityConfig.Rarity = Rarity
AbilityConfig.Abilities = {
	SpawnInvulnerability = {
		Unlisted = true,
		Duration = 3,
		Transparency = 0.75,
	},
	Dash = {
		Order = 1,
		Rarity = Rarity.Common,
		Icon = "rbxassetid://88569411185376",	
		Price = { Price = 0 },
		Cooldown = 3.0,
		
		-- CONFIG
		Velocity = 75,
		Duration = 0.2,
		Sound = "Dash",
	},
	Shrink = {
		Order = 2,
		Rarity = Rarity.Common,
		Icon = "rbxassetid://125873903836357",
		Price = { Price = 250 },
		Cooldown = 10.0,
		
		-- CONFIG
		Scale = 0.2,
		ScaleWeapon = false, -- false keeps the equipped weapon at its current size
		TweenTime = 0.5,
		Duration = 4.0,		
	},
	Invisible = {
		Order = 3,
		Rarity = Rarity.Common,
		Icon = "rbxassetid://121839492367614",
		Price = { Price = 500 },
		Cooldown = 10.0,

		-- CONFIG
		Transparency = 0.95,
		Duration = 5.0,
	},
	MegaJump = {
		Order = 4,
		Rarity = Rarity.Common,
		Icon = "rbxassetid://78794119577901",
		Price = { Price = 750 },
		Cooldown = 12,
		
		-- CONFIG
		Force = 200,
	},
	Pull = {
		Order = 5,
		Rarity = Rarity.Rare,
		Icon = "rbxassetid://125586046159211",	
		Price = { Price = 1250 },
		Cooldown = 15.0,

		-- CONFIG
		Duration = 0.6,
		ReleaseTime = 0.35,
		Range = 50,
		Angle = 40,
		KnockbackProfile = "Equipped",
		Strength = 1.0,
		Animation = "rbxassetid://109087527689927",
	},
	Push = {
		Order = 6,
		Rarity = Rarity.Rare,
		Icon = "rbxassetid://91215228363585",	
		Price = { Price = 2500 },
		Cooldown = 15.0,

		-- CONFIG
		Duration = 0.5,
		ReleaseTime = 0.35,
		Range = 45,
		Angle = 50,
		KnockbackProfile = "Equipped",
		Strength = 1.5,
		Animation = "rbxassetid://90129738658187",
	},
	Charge = {
		Order = 7,
		Rarity = Rarity.Epic,
		Icon = "rbxassetid://134637905456407",	
		Price = { Price = 3000 },
		Cooldown = 15.0,

		-- CONFIG		
		-- movement (client runs the humanoid, the server only checks hits)
		RunSpeed = 40,      -- WalkSpeed during the charge
		Duration = 2.0,
		TurnRate = 140,      -- degrees / second the charger can steer towards where the camera looks (lower = easier to dodge)
		SlowDown = 0.3,      -- the last seconds are spent braking down to normal speed (skid)
		Animation = 139508649486579, -- run animation (looped while charging)

		-- hitbox (server). Placed in front of the charger and always faces the way he runs.
		HitboxSize = Vector3.new(8, 6, 9),     -- width, height, length (studs)
		HitboxOffset = Vector3.new(0, 0, -3),  -- relative to the charger; negative Z = in front of him
		LeadTime = 0.1,      -- the server sees the charger a bit behind his screen: the box is stretched forward by speed * LeadTime
		MaxLead = 14,        -- studs, cap of that stretch
		MaxHitDistance = 16, -- anybody farther than this from the charger is ignored

		-- knockback: SAME ragdoll system as the M1 attack
		KnockbackProfile = "Equipped", -- the charger's equipped weapon profile ("Slap" if none), or a fixed profile name
		Strength = 1.35,     -- 1 .. 1.5
		SideKnock = 0.6,     -- 0 = everybody flies straight ahead, higher = thrown to the side they were standing on
	},
	Throw = {
		Order = 8,
		Rarity = Rarity.Epic,
		Icon = "rbxassetid://122648477029355",	
		Price = { Price = 4000 },
		Cooldown = 16.0,

		-- CONFIG		
		Animation = 135574223916354,
		ReleaseTime = 0.3,
		Range = 55,
		Curve = 12,
		OutTime = 0.55,
		HoverTime = 0.3,
		ReturnTime = 0.7,
		Duration = 2.2,             -- Must be greater than (ReleaseTime + OutTime + HoverTime + ReturnTime)
		SpinSpeed = 26,
		HitRadius = 6,
		KnockbackProfile = "Equipped", -- Valid profile name from WeaponConfig
		Strength = 1.0,            -- Must be between 1.0 and 1.5
	},

	-- Add inside AbilityConfig.Abilities table:
	Smash = {
		Order = 9,
		Rarity = Rarity.Epic,
		Icon = "rbxassetid://122721718593293",	
		Price = { Price = 5000 },
		Cooldown = 20.0,

		-- CONFIG
		-- animations
		M2 = "rbxassetid://131992617763597",        -- plays during the whole jump + slam
		DownSlam = "rbxassetid://134630672185082",  -- optional extra animation layered on the dive
		UseDownSlam = false,

		-- M2 animation timeline (seconds of the ANIMATION at speed 1)
		M2Length = 2.5,      -- total length of M2
		ImpactTime = 1.97,   -- animation time of the slam frame: the character lands exactly here
		DiveAnimTime = 0.3,  -- the last stretch before the slam frame is the dive; everything before it is "up in the air"

		-- how high / how slow the jump is
		JumpHeight = 26,     -- studs above the take-off point (higher = longer fall = bigger slam)
		RiseSpeed = 0.75,    -- animation speed on the way up and while hanging (1 = original, lower = slower / floatier)
		DiveSpeed = 1.0,     -- animation speed during the dive
		RiseFraction = 0.5,  -- part of the way-up time spent climbing; the rest is hang time at the top
		HitStop = 0.07,      -- seconds the animation freezes on the slam frame (crunch)

		-- steering (WASD)
		HangSteer = 14,      -- while climbing / hanging
		SteerSpeed = 20,     -- during the dive
		SlamSpeed = 160,     -- fastest the dive may go (studs/s)

		-- area of effect (server side)
		HitRadius = 17,      -- studs around the landing point
		VerticalReach = 10,  -- targets higher/lower than this are ignored

		-- knockback: uses the SAME ragdoll/fling system as the normal M1 attack.
		-- "Equipped" = every smashed player/NPC/bag is launched with the smasher's equipped weapon
		-- profile, exactly like an M1 hit with that weapon (strength 1.1 .. 1.5 by distance).
		KnockbackProfile = "Equipped",
		HitEffectWeapon = "Equipped",
		MinStrength = 1.1,   -- strength at the edge of the radius   (ApplyHit accepts 1 .. 1.5)
		MaxStrength = 1.5,   -- strength at the centre
	},
	-- ==========================================
	-- BIG WEAPON: the equipped weapon grows [Scale] times, then a huge circular hit launches everybody around you.
	-- ==========================================
	BigWeapon = {
		Order = 10,
		Rarity = Rarity.Legendary,
		Icon = "rbxassetid://113092587432189", 
		Price = { Price = 8000 },
		Cooldown = 30,

		Scale = 3.5,                  -- the weapon becomes this many times larger (1 = no change)
		ServerScaleInterval = 0,     -- 0 = instant; positive seconds = stepped server resizing during GrowTime/ShrinkTime.
		-- An interval >= the transition duration also applies the final size immediately.
		GrowTime = 0.3,             -- seconds the weapon takes to grow
		ReleaseTime = 0.45,         -- seconds after the cast until the big hit lands (must be < Duration)
		Duration = 8,             -- seconds the weapon stays big before it shrinks back
		ShrinkTime = 0.25,          -- seconds the weapon takes to shrink back
		
		-- Animation = "rbxassetid://...", -- optional cast animation (uncomment and insert id)

		-- big hitbox (server): a circle around the caster
		HitRadius = 35,             -- studs around the caster
		VerticalReach = 15,         -- targets higher/lower than this are ignored

		-- knockback: SAME ragdoll system as M1 / Smash
		KnockbackProfile = "Equipped",
		HitEffectWeapon = "Equipped",
		MinStrength = 1.2,          -- strength at the edge of the radius (ApplyHit accepts 1 .. 1.5)
		MaxStrength = 1.5,          -- strength at the centre

		-- sounds: paste an asset id ("rbxassetid://123" or just 123). Empty string = no sound.
		Sounds = {
			Cast = "rbxassetid://125914564702009",
			Impact = "rbxassetid://127539968829015",
		},
	},

	-- ==========================================
	-- TIME TRAVEL: 1st right click leaves a ghost of you, 2nd right click teleports you back to it.
	-- ========================================== DISABLE FOR NOW
	 

	-- ==========================================
	-- SHADOW CLONE (Naruto): summons [CloneCount] copies of you with your weapon.
	-- They chase the nearest enemy and attack automatically (same hit / knockback system as M1).
	-- Clones never hurt you, hits are credited to you, and a clone pops after [HitsToDispel] hits.
	-- ==========================================
	ShadowClone = {
		Unlisted = true,
		Order = 11,
		Rarity = Rarity.Legendary,
		Icon = "",                   -- TODO: insert icon asset id (rbxassetid://...)
		Price = { Price = 3000 },
		Cooldown = 10.0,

		-- CONFIG
		Duration = 12,               -- seconds the clones stay before they vanish
		CloneCount = 2,              -- how many clones you summon (1 .. 8)
		SpawnRadius = 2,             -- studs around you where they appear
		SpawnPuff = true,            -- smoke poof on spawn (also used when they vanish)
		Transparency = 0,            -- 0 = identical to you, e.g. 0.3 = slightly ghostly

		-- behaviour
		SpeedMultiplier = 1.15,      -- clone WalkSpeed = GameConfig.Movement.WalkSpeed * this
		ChaseRange = 90,             -- studs; enemies farther than this are ignored
		AttackChargeMin = 0.4,       -- seconds a clone "charges" its swing (random between min and max)
		AttackChargeMax = 0.8,       -- (charge time also decides the knockback strength, like for NPCs)
		TargetNpcs = true,           -- also chase Arena / Lobby NPCs (handy for training)

		-- clone health
		HitsToDispel = 2,            -- hits a clone survives before it pops
		DispelDelay = 0.75,          -- seconds between the hit and the pop (lets the knockback flight show)
	},

	-- ==========================================
	-- SHIELD: a shining shield surrounds you and blocks the FIRST hit you take, then it breaks.
	-- If nobody hits you it fades after [Duration] seconds.
	-- ==========================================
	Shield = {
		Unlisted = true,
		Order = 12,
		Rarity = Rarity.Common,
		Icon = "",                  -- TODO: insert icon asset id (rbxassetid://...)
		Price = { Price = 600 },
		Cooldown = 15.0,

		-- CONFIG
		Duration = 12,              -- seconds the shield stays if nobody hits you
		AbsorbWindow = 0.1,        -- seconds after the break in which the SAME attack (multi-hit) is still blocked

		-- visual (client)
		Image = "",                 -- optional shield emblem shown on the bubble: paste an asset id ("rbxassetid://123"). Empty = bubble only
		Color = Color3.fromRGB(110, 200, 255),
		Size = 8,                   -- bubble diameter in studs (the character is ~5 tall, so 8 = fat bubble)
		
	},
	TimeTravel = { 
		Unlisted = true,
		Order = 13,
		Rarity = Rarity.Legendary,
		Icon = "",                  -- TODO: insert icon asset id (rbxassetid://...)
		Price = { Price = 2000 },
		Cooldown = 12.0,            -- starts when the ability ENDS (you returned, or the ghost faded)

		Duration = 6.0,             -- seconds the ghost waits for the 2nd right click, then it fades away
		KeepVelocity = false,       -- true = keep your speed when you arrive at the ghost

		GhostColor = Color3.fromRGB(108, 81, 99),
		GhostColor2 = Color3.fromRGB(190, 120, 255),
		GhostTransparency = 0.55,

		-- sounds: paste an asset id ("rbxassetid://123" or just 123). Empty string = no sound.
		Sounds = {
			Set = "rbxassetid://86879740891641",               -- 1st right click: ghost appears
			Return = "rbxassetid://6920047468",            -- 2nd right click: you teleport back
			Expire = "",
		},
	},
	

	TimeStop = {
		Order = 112,
		Rarity = Rarity.Mythic,
		Icon = "rbxassetid://99257402220050",	
		Price = { Price = 3721053479, IsRobux = true },
		CooldownAfter = 60,         -- cooldown starts counting when the stop ENDS (see derived values below)
		
		-- CONFIG
		Animation = "rbxassetid://115589580889052", -- caster pose
		ReadyTime = 2.5,            -- telegraph length in seconds (2-3 recommended). NOT tied to the TimeReady sound anymore.
		ReadySoundMode = "Trim",    -- "Trim"  = play only the LAST ReadyTime seconds of TimeReady
		-- "Speed" = play the whole sound faster so it fits
		-- "None"  = play it untouched (ignores ReadyTime for the sound)
		StopDuration = 5,           -- seconds the world is frozen
		Radius = 200,               -- studs around the caster (arena only; the lobby is never affected)
		AttackCooldownScale = 0.35, -- caster's M1 cooldown is multiplied by this while time is stopped (1 = off)

		-- hits stored during the stop are released after it ends
		HitInterval = 0.08,         -- seconds between the barrage hits
		PerHitKnockback = 0.08,     -- final launch: +8% knockback multiplier per stored hit
		MaxKnockbackMultiplier = 2.5,
		FinishStrength = 1.1,       -- final launch strength at 1 hit (ApplyHit accepts 1 .. 1.5)
		FinishStrengthPerHit = 0.04,-- + this per extra hit, capped at 1.5
	},
}

-- Derived timing (do not edit): how long the jump really takes with the values above.
--   up-time  = (ImpactTime - DiveAnimTime) / RiseSpeed      (slower animation = longer in the air)
--   air-time = up-time + DiveAnimTime / DiveSpeed           (the server only accepts a landing after ~60% of this)
local smash = AbilityConfig.Abilities.Smash
smash.AirTime = (smash.ImpactTime - smash.DiveAnimTime) / smash.RiseSpeed + smash.DiveAnimTime / smash.DiveSpeed
smash.Duration = smash.AirTime + 1.2 -- the server / client give up after this


-- Derived TimeStop timing (do not edit)
local ts = AbilityConfig.Abilities.TimeStop
ts.TotalTime = ts.ReadyTime + ts.StopDuration
ts.Duration = ts.TotalTime + 1                 -- CombatService clears the effect after this (grace)
ts.Cooldown = ts.TotalTime + ts.CooldownAfter  -- cooldown runs from the cast, so this really is "after it ends"
	
return AbilityConfig
