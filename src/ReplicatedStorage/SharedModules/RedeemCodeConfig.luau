
return {
	["WELCOME"] = {
		Message = "You got 500 coins!",
		Reward = function(player)
			-- put your reward logic here, example:
			player:SetAttribute("Coins", math.round((player:GetAttribute("Coins") or 0) + 500))
		end,
	},

	["RELEASE"] = {
		Message = "Release reward claimed!",
		Expires = os.time({ year = 2026, month = 12, day = 31, hour = 23, min = 59 }), -- optional, UTC
		Reward = function(player)
			-- ...
		end,
	},

	["OLDCODE"] = {
		Enabled = false, -- optional: turn a code off without deleting it
		Reward = function(player) end,
	},
}