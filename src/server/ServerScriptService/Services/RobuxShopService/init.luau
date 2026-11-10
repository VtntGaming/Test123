--!strict
local PurchaseService = require(game:GetService("ServerScriptService").Services.PurchaseService)

local Service = {}
local started = false
local sections: { { Name: string, Load: () -> any } } = {
	{
		Name = "CoinPacks",
		Load = function()
			return require(script.Sections.CoinPacks)
		end,
	},
	{
		Name = "StarterPack",
		Load = function()
			return require(script.Sections.StarterPack)
		end,
	},
	{
		Name = "LimitedItem",
		Load = function()
			return require(script.Sections.LimitedItem)
		end,
	},
	{
		Name = "LuckyChest",
		Load = function()
			return require(script.Sections.LuckyChest)
		end,
	},
	{
		Name = "WeaponPacks",
		Load = function()
			return require(script.Sections.WeaponPacks)
		end,
	},
	{
		Name = "Passes",
		Load = function()
			return require(script.Sections.Passes)
		end,
	},
}

function Service.Init()
	if started then
		return
	end
	started = true
	for _, section in ipairs(sections) do
		local function initialize()
			local ok, err = pcall(function()
				local sectionModule = section.Load()
				sectionModule.Init(PurchaseService.Register)
			end)
			if not ok then
				warn("[RobuxShopService] " .. section.Name .. " will retry: " .. tostring(err))
				task.delay(30, initialize)
			end
		end
		task.spawn(initialize)
	end
end
return Service
