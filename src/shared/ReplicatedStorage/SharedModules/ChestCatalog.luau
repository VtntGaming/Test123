--!strict
-- Inventory identity and reward metadata are independent of presentation assets.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChestConfig = require(script.Parent.ChestConfig)
local ShopConfig = require(script.Parent.RobuxShopConfig)
local DailyChestConfig = require(script.Parent.DailyChestConfig)

export type ChestCatalog = {
	LuckyId: (group: string) -> string,
	Get: (chestId: string) -> any,
}

local Catalog = {} :: ChestCatalog

function Catalog.LuckyId(group: string): string
	return "LuckyChest:" .. group
end

function Catalog.Get(chestId: string): any
	if chestId == DailyChestConfig.ChestType then
		local wooden = ChestConfig.Chests.Wooden
		local models = ReplicatedStorage.Assets.Chests
		local model = models:FindFirstChild(DailyChestConfig.ModelName)
		if not model or not model:IsA("Model") then model = models:FindFirstChild("Wooden") end
		return {
			Id = chestId,
			Name = chestId,
			DisplayName = DailyChestConfig.DisplayName,
			Order = DailyChestConfig.Order,
			RewardKind = "Normal",
			Rates = DailyChestConfig.Rates,
			Thumbnail = if DailyChestConfig.Thumbnail ~= "" then DailyChestConfig.Thumbnail else wooden.Thumbnail,
			Color = DailyChestConfig.Color,
			ModelPath = if model and model:IsA("Model") then model else nil,
		}
	end
	local normal: any = ChestConfig.GetChestInfo(chestId)
	if normal then
		normal.Id = chestId
		normal.DisplayName = chestId .. " Chest"
		normal.RewardKind = "Normal"
		local wooden = ChestConfig.Chests.Wooden
		if normal.Thumbnail == "" then normal.Thumbnail = wooden.Thumbnail end
		if not normal.ModelPath or not normal.ModelPath:IsA("Model") then
			normal.ModelPath = ReplicatedStorage.Assets.Chests:FindFirstChild("Wooden")
		end
		return normal
	end
	local group = string.match(chestId, "^LuckyChest:(.+)$")
	if not group then return nil end
	local pack = ShopConfig.LuckyChestPacks[group]
	if not pack then return nil end
	local names = {}
	for name in pairs(ShopConfig.LuckyChestPacks) do table.insert(names, name) end
	table.sort(names)
	local wooden = ChestConfig.Chests.Wooden
	local models = ReplicatedStorage.Assets.Chests
	local model = models:FindFirstChild(pack.ModelName or group)
	if not model or not model:IsA("Model") then model = models:FindFirstChild("Wooden") end
	return {
		Id = chestId,
		Name = group,
		DisplayName = group .. " Chest",
		Order = 100 + (table.find(names, group) or 0),
		RewardKind = "LuckyVariant",
		Group = group,
		Description = "100% random " .. group .. " weapon",
		Thumbnail = if type(pack.Thumbnail) == "string" and pack.Thumbnail ~= "" then pack.Thumbnail else wooden.Thumbnail,
		Color = wooden.Color,
		ModelPath = if model and model:IsA("Model") then model else nil,
	}
end

return Catalog
