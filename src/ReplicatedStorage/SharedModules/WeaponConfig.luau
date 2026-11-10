 WeaponConfig = {}

-- Global hit VFX: "HitEffect" uses Assets.VFX.HitEffect; "WeaponBasedHitEffect" uses HitEffects[full weapon name].
-- Weapon-based mode falls back to HitEffect when the matching template is missing or unsupported.
WeaponConfig.HitEffectMode = "WeaponBasedHitEffect"

-- Layer Assets.SFX.WeaponEffects[variant] over the normal HitSound on confirmed weapon hits.
WeaponConfig.WeaponEffectSoundEnabled = true

-- Shared charge slowdown settings; weapon-specific power is configured in BaseWeapons below.
WeaponConfig.ChargedJumpAttack = {
	Enable = true, -- False: airborne attacks release immediately, without charge slowdown or charge strength.
	MinHoldTime = 0.2, -- Seconds held after an airborne attack starts before charged-jump effects apply.
	StopTime = 1, -- Seconds after MinHoldTime to reduce WalkSpeed and horizontal momentum to zero.
	EasingStyle = Enum.EasingStyle.Quad, -- Curve for slowing from the starting speed to zero during StopTime.
	EasingDirection = Enum.EasingDirection.Out, -- Out brakes quickly at first; In starts gently; InOut blends both.
}

-- Visual-only "charging mode" for the equipped weapon while holding left click.
WeaponConfig.ChargeVfx = {
	Enable = true,
	MaxScale = 2,
	MaxBrightness = 1.5,
	LightEmissionBoost = 0.5,
	RateMultiplier = 2,
	PulseAmount = 0.35,
	PulseSpeed = 18,
	ResetTime = 0.2,
	PopScale = 0.35,
	PopBurst = 6,
	Light = { Color = Color3.fromRGB(255, 240, 150), Brightness = 4, Range = 14 },
	Highlight = { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.35 }, -- weapon outline

	-- Camera: zooms in while charging, punches out at full charge. nil = off.
	Fov = { ZoomIn = 6, PunchOut = 5, PunchTime = 0.08, ReturnTime = 0.2 },

	-- Glow on your own character. nil = off.
	CharacterHighlight = {
		Color = Color3.fromRGB(255, 200, 80),
		FlashColor = Color3.fromRGB(255, 255, 255),
		FillTransparency = 0.82,       -- fill at full charge (1 = invisible)
		FlashFillTransparency = 0.35,  -- fill during the flash at full charge
		OutlineTransparency = 0.2,
	},

	Sound = "HoldCharge", -- SoundService.SFX.<name>, played once at full charge. nil = off.
	SoundVolume = 5,
}
-- ==========================================
-- RARITY & LIMITS
-- ==========================================
WeaponConfig.Rarities = {
	Common = Color3.fromRGB(255, 255, 255),
	Rare = Color3.fromRGB(85, 170,	 255),
	Epic = Color3.fromRGB(170, 85, 255),
	Legendary = Color3.fromRGB(255, 255, 0),
	Mythic = Color3.fromRGB(255, 0, 0),
}

WeaponConfig.RarityLimits = {
	Common = 999999, 
	Rare = 500000,
	Epic = 50000,
	Legendary = 10000,
	Mythic = 500
}

-- ==========================================
-- WEAPONS & VARIANTS
-- ==========================================
-- Attack and JumpAttack each define their animation, charge timing and hitbox.
-- Windup, TrackLength and HitboxDuration are seconds; TrackChargeThreshold is a 0..1 animation fraction.
-- Holding a charge reduces Windup using TrackLength; the result never goes below zero.
-- HitboxSize is width/height/depth in studs. HitboxOffset is relative to HumanoidRootPart; negative Z is forward.
-- HitboxDuration = 0 checks once. JumpAttack applies when the attack starts airborne, even if jump charging is disabled.
-- Cosmetic variants inherit their base weapon's settings.
-- Cooldown is seconds after release, shared by ground and jump attacks for that weapon.
-- Each attack's KnockbackMultiplier scales its knockback profile on top of charge strength; 1 is unchanged.
-- JumpAttack.KnockbackMultiplier applies to quick and charged jump attacks alike.
WeaponConfig.BaseWeapons = {
	Slap = {
		Idle = "rbxassetid://133470345001946",
		HitSound = "SlapHit",
		Cooldown = 1,
		Attack = {
			KnockbackMultiplier = 1,
			AnimationId = "rbxassetid://140487373966464",
			Windup = 0.15,
			TrackLength = 1,
			TrackChargeThreshold = 0.4/1,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 11),
			HitboxOffset = Vector3.new(0, 0, -1),
		},
		JumpAttack = {
			KnockbackMultiplier = 1.1,
			AnimationId = "rbxassetid://120152734035407",
			Windup = 0.2,
			TrackLength = 1.2,
			TrackChargeThreshold = 0.2/1.2,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(11, 8, 11),
			HitboxOffset = Vector3.new(0, -5, -1),
		},
	},
	Bat = {
		Idle = "rbxassetid://136887240749450",
		HitSound = "BatHit",
		Cooldown = 1,
		Attack = {
			KnockbackMultiplier = 1,
			AnimationId = "rbxassetid://121943566023411",
			Windup = 0.15,
			TrackLength = 1,
			TrackChargeThreshold = 0.4,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 11),
			HitboxOffset = Vector3.new(0, 0, -1),
		},
		-- JumpAttack = {
		-- 	KnockbackMultiplier = 1.25,
		-- 	AnimationId = "rbxassetid://76056541086702",
		-- 	Windup = 0.15,
		-- 	TrackLength = 0.7,
		-- 	TrackChargeThreshold = 0.3/0.7,
		-- 	HitboxDuration = 0.4,
		-- 	HitboxSize = Vector3.new(8, 8, 11),
		-- 	HitboxOffset = Vector3.new(0, -5, -1),
		-- },
		JumpAttack = {
			KnockbackMultiplier = 1.25,
			AnimationId = "rbxassetid://113504311752545",
			Windup = 0.1,
			TrackLength = 0.7,
			TrackChargeThreshold = 0.33/0.7,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 11),
			HitboxOffset = Vector3.new(0, -5, -1),
		},
	},
	Hammer = {
		Idle = "rbxassetid://136887240749450",
		HitSound = "HammerHit",
		Cooldown = 1.5,
		Attack = {
			KnockbackMultiplier = 1.15,
			AnimationId = "rbxassetid://121943566023411",
			Windup = 0.15,
			TrackLength = 1,
			TrackChargeThreshold = 0.4/1,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 11),
			HitboxOffset = Vector3.new(0, 0, -1),
		},
		JumpAttack = {
			KnockbackMultiplier = 1.325,
			AnimationId = "rbxassetid://87456393644569",
			-- Alternative jump attack: 88062314080994; current animation is downslam.
			Windup = 0.15,
			TrackLength = 1,
			TrackChargeThreshold = 0.2/1,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 11),
			HitboxOffset = Vector3.new(0, -5, -1),
		},
	},
	Stick = {
		Idle = "rbxassetid://138772609134001",
		HitSound = "StickHit",
		Cooldown = 0.9,
		Attack = {
			KnockbackMultiplier = 0.9,
			AnimationId = "rbxassetid://118268387567339",
			Windup = 0.1,
			TrackLength = 0.67,
			TrackChargeThreshold = 0.2/0.67,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 11),
			HitboxOffset = Vector3.new(0, 0, -1),
		},
		JumpAttack = {
			KnockbackMultiplier = 1.25,
			AnimationId = "rbxassetid://113504311752545",
			Windup = 0.1,
			TrackLength = 0.7,
			TrackChargeThreshold = 0.33/0.7,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 11),
			HitboxOffset = Vector3.new(0, -5, -1),
		},
	},
	Chicken = {
		Idle = "rbxassetid://110148773140015",
		HitSound = "ChickenHit",
		Cooldown = 0.75,
		Attack = {
			KnockbackMultiplier = 0.85,
			AnimationId = "rbxassetid://76841718401649",
			Windup = 0.125,
			TrackLength = 0.9,
			TrackChargeThreshold = 0.35/0.9,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 13),
			HitboxOffset = Vector3.new(0, 0, -1),
		},
		JumpAttack = {
			KnockbackMultiplier = 1.1,
			AnimationId = "rbxassetid://102639694528218",
			Windup = 0.125,
			TrackLength = 0.7,
			TrackChargeThreshold = 0.35/0.7,
			HitboxDuration = 0.4,
			HitboxSize = Vector3.new(8, 8, 11),
			HitboxOffset = Vector3.new(0, -5, -1),
		},
	},
}

WeaponConfig.RarityVariants = {
	Common = {"Blue", "Red", "Green", "Yellow"},
	Rare = {"Wood", "Stone", "Silver", "Gold", "Diamond"},
	Epic = {"Fire", "Ice", "Lightning"},
	Legendary = {"King", "Demon", "Samourai", "Beast"},
	Mythic = {"Celestial", "Magical", "Rainbow"}
}

-- ==========================================
-- ICONS
-- ==========================================
WeaponConfig.Icons = {
	-- Bats (21)
	["Bat"] = "rbxassetid://77473574607840",
	["BatBeast"] = "rbxassetid://77485004562703",
	["BatBlue"] = "rbxassetid://100344695987548",
	["BatCelestial"] = "rbxassetid://95546783540453",
	["BatDemon"] = "rbxassetid://88337829685415",
	["BatDiamond"] = "rbxassetid://79879167653264",
	["BatFire"] = "rbxassetid://95825481599251",
	["BatGold"] = "rbxassetid://129463742772553",
	["BatGreen"] = "rbxassetid://110218226880648",
	["BatIce"] = "rbxassetid://72990766894412",
	["BatKing"] = "rbxassetid://117907391696140",
	["BatLightning"] = "rbxassetid://75499318198216",
	["BatMagical"] = "rbxassetid://86373571240213",
	["BatPink"] = "rbxassetid://114909465532091",
	["BatRainbow"] = "rbxassetid://98275080662645",
	["BatRed"] = "rbxassetid://74168289432966",
	["BatSamourai"] = "rbxassetid://94617168506768",
	["BatSilver"] = "rbxassetid://101386509847584",
	["BatStone"] = "rbxassetid://70396256967364",
	["BatWood"] = "rbxassetid://121094540541285",
	["BatYellow"] = "rbxassetid://121410109127841",

	-- Chickens (21)
	["Chicken"] = "rbxassetid://97049487414048",
	["ChickenBeast"] = "rbxassetid://126911491304797",
	["ChickenBlue"] = "rbxassetid://77335252077918",
	["ChickenCelestial"] = "rbxassetid://121598786501349",
	["ChickenDemon"] = "rbxassetid://109489623257364",
	["ChickenDiamond"] = "rbxassetid://83606961110217",
	["ChickenFire"] = "rbxassetid://77729582498161",
	["ChickenGold"] = "rbxassetid://101465422923624",
	["ChickenGreen"] = "rbxassetid://96487189004724",
	["ChickenIce"] = "rbxassetid://115140946805494",
	["ChickenKing"] = "rbxassetid://116251519736862",
	["ChickenLightning"] = "rbxassetid://126222806973289",
	["ChickenMagical"] = "rbxassetid://104419141214652",
	["ChickenPink"] = "rbxassetid://91201207776675",
	["ChickenRainbow"] = "rbxassetid://99397507980754",
	["ChickenRed"] = "rbxassetid://71110654423790",
	["ChickenSamourai"] = "rbxassetid://76139246616678",
	["ChickenSilver"] = "rbxassetid://88573389580576",
	["ChickenStone"] = "rbxassetid://136738831757984",
	["ChickenWood"] = "rbxassetid://132921132163797",
	["ChickenYellow"] = "rbxassetid://116516380726173",

	-- Hammers (21)
	["Hammer"] = "rbxassetid://132974644100357",
	["HammerKaido"] = "rbxassetid://135455054461214",
	["HammerBeast"] = "rbxassetid://102080708023015",
	["HammerBlue"] = "rbxassetid://117319997973462",
	["HammerCelestial"] = "rbxassetid://132654330448841",
	["HammerDemon"] = "rbxassetid://96293613480635",
	["HammerDiamond"] = "rbxassetid://119750609874513",
	["HammerFire"] = "rbxassetid://93503503106173",
	["HammerGold"] = "rbxassetid://86550317299970",
	["HammerGreen"] = "rbxassetid://112183693105872",
	["HammerIce"] = "rbxassetid://138121850681292",
	["HammerKing"] = "rbxassetid://91859734876936",
	["HammerLightning"] = "rbxassetid://132197112005894",
	["HammerMagical"] = "rbxassetid://123049112353426",
	["HammerPink"] = "rbxassetid://115972932885317",
	["HammerRainbow"] = "rbxassetid://109465471568639",
	["HammerRed"] = "rbxassetid://106723156306784",
	["HammerSamourai"] = "rbxassetid://118051641492144",
	["HammerSilver"] = "rbxassetid://78497782512328",
	["HammerStone"] = "rbxassetid://111028750018583",
	["HammerWood"] = "rbxassetid://139538872666357",
	["HammerYellow"] = "rbxassetid://76279606872377",

	-- Slaps (21)
	["Slap"] = "rbxassetid://108291107074342",
	["SlapBeast"] = "rbxassetid://80787077413970",
	["SlapBlue"] = "rbxassetid://132356648111752",
	["SlapCelestial"] = "rbxassetid://79088564327163",
	["SlapDemon"] = "rbxassetid://73105872142416",
	["SlapDiamond"] = "rbxassetid://134846092329024",
	["SlapFire"] = "rbxassetid://120921841513867",
	["SlapGold"] = "rbxassetid://72865211680909",
	["SlapGreen"] = "rbxassetid://93637363303219",
	["SlapIce"] = "rbxassetid://124746934692973",
	["SlapKing"] = "rbxassetid://110773357537928",
	["SlapLightning"] = "rbxassetid://100941364238852",
	["SlapMagical"] = "rbxassetid://140220510657378",
	["SlapPink"] = "rbxassetid://87317608456371",
	["SlapRainbow"] = "rbxassetid://106259603973412",
	["SlapRed"] = "rbxassetid://131947743816511",
	["SlapSamourai"] = "rbxassetid://106797089800182",
	["SlapSilver"] = "rbxassetid://105236907160291",
	["SlapStone"] = "rbxassetid://119007322884750",
	["SlapWood"] = "rbxassetid://88002011641045",
	["SlapYellow"] = "rbxassetid://103168075627466",

	-- Sticks (21)
	["Stick"] = "rbxassetid://76212723343567",
	["StickBeast"] = "rbxassetid://117191058061270",
	["StickBlue"] = "rbxassetid://113410078978680",
	["StickCelestial"] = "rbxassetid://114576817610932",
	["StickDemon"] = "rbxassetid://114137745615868",
	["StickDiamond"] = "rbxassetid://98588034930613",
	["StickFire"] = "rbxassetid://101436297943967",
	["StickGold"] = "rbxassetid://101422273733188",
	["StickGreen"] = "rbxassetid://82379628386960",
	["StickIce"] = "rbxassetid://129241136456956",
	["StickKing"] = "rbxassetid://83198334203117",
	["StickLightning"] = "rbxassetid://84313663021304",
	["StickMagical"] = "rbxassetid://122112937041035",
	["StickPink"] = "rbxassetid://77207909188960",
	["StickRainbow"] = "rbxassetid://137011496546378",
	["StickRed"] = "rbxassetid://107575366668968",
	["StickSamourai"] = "rbxassetid://123575853355103",
	["StickSilver"] = "rbxassetid://93330930639436",
	["StickStone"] = "rbxassetid://123180638845210",
	["StickWood"] = "rbxassetid://74863670818099",
	["StickYellow"] = "rbxassetid://108825525020382",
}

export type RatityWeaponData = {
	Name: string,
	Image: string,
}

WeaponConfig.RarityWeaponIcons = {} :: {[string]: {RatityWeaponData}}

-- ==========================================
-- FUNCTIONS
-- ==========================================
export type AttackSettings = {
	KnockbackMultiplier: number,
	AnimationId: string,
	Windup: number,
	TrackLength: number,
	TrackChargeThreshold: number,
	HitboxDuration: number,
	HitboxSize: Vector3,
	HitboxOffset: Vector3,
}

export type WeaponInfo = {
	BaseName: string,
	Variant: string,
	Rarity: string,
	RarityColor: Color3,
	Idle: string,
	Cooldown: number,
	Attack: AttackSettings,
	JumpAttack: AttackSettings,
	HitSound: string,
	Icon: string,
	FullName: string,
	DisplayName: string
}

function WeaponConfig.GetWeaponInfo(fullWeaponName): WeaponInfo
	local baseWeaponName, variantName, rarityName, displayName = nil, "None", "Common", nil

	for name, _ in pairs(WeaponConfig.BaseWeapons) do
		if string.sub(fullWeaponName, 1, string.len(name)) == name then
			baseWeaponName = name
			local remainder = string.sub(fullWeaponName, string.len(name) + 1)
			if remainder ~= "" then variantName = remainder end
			break
		end
	end

	do -- KAIDO SPECIAL
		if fullWeaponName == "HammerKaido" then
			baseWeaponName, variantName, rarityName, displayName = "Hammer", "Kaido", "Mythic", "Kaido"
		end
	end

	if not baseWeaponName then return nil end

	if variantName ~= "None" then
		for rName, variants in pairs(WeaponConfig.RarityVariants) do
			if table.find(variants, variantName) then rarityName = rName; break end
		end
	end

	local baseData = WeaponConfig.BaseWeapons[baseWeaponName]

	if not displayName then
	 	displayName = (variantName == "None") and baseWeaponName or (variantName .. " " .. baseWeaponName)
	end

	return {
		BaseName = baseWeaponName,
		Variant = variantName,
		Rarity = rarityName,
		RarityColor = WeaponConfig.Rarities[rarityName],
		Idle = baseData.Idle,
		Cooldown = baseData.Cooldown,
		Attack = baseData.Attack,
		JumpAttack = baseData.JumpAttack,
		HitSound = baseData.HitSound,
		Icon = (WeaponConfig.Icons and WeaponConfig.Icons[fullWeaponName]) or "",
		FullName = fullWeaponName,
		DisplayName = displayName
	}
end

-- Put in the list
for weaponName, image in WeaponConfig.Icons do
	local data = WeaponConfig.GetWeaponInfo(weaponName)
	local rarity = data and data.Rarity

	if not rarity then
		continue
	end

	if not WeaponConfig.RarityWeaponIcons[rarity] then
		WeaponConfig.RarityWeaponIcons[rarity] = {}
	end

	local rarityList = WeaponConfig.RarityWeaponIcons[rarity]
	table.insert(rarityList, {
		Name = weaponName,
		Icon = image
	})
end

return WeaponConfig
