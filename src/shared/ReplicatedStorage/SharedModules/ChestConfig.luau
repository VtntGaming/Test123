local ChestConfig = {}

ChestConfig.RestockTimeSeconds = 300

export type ChestRates = {
	Common: number,
	Rare: number,
	Epic: number,
	Legendary: number,
	Mythic: number,
}

export type ChestData = {
	Order: number,
	Thumbnail: string,
	Color: Color3,
	Cost: number,
	CostInRobux: number,
	ProductId: number,
	UnlockTimeMin: number,
	CopiesContained: number,
	Rates: ChestRates,
	ShopDropRate: number,
	ShopAmountRate: {number},
}

export type ChestInfo = ChestData & {
	Name: string,
	ModelPath: Instance?,
}

ChestConfig.Chests = {
	Wooden = { 
		Order = 1, Thumbnail = "rbxassetid://74107152687727",Color = Color3.fromHex("#733A00"),
		Cost = 50, CostInRobux = 5, ProductId = 3726323164,
		Rates = {Common = 60, Rare = 35, Epic = 5, Legendary = 0, Mythic = 0}, ShopDropRate = 100, ShopAmountRate = {3, 6},
		--UnlockTimeMin = 0, CopiesContained = 8,
	},
	Silver = {
		Order = 2, Thumbnail = "rbxassetid://98193398215157", Color = Color3.fromHex("#00AAFF"),
		Cost = 125, CostInRobux = 9, ProductId = 3726323454,
		Rates = {Common = 28, Rare = 55, Epic = 15, Legendary = 2, Mythic = 0}, ShopDropRate = 80, ShopAmountRate = {2, 4},
		--UnlockTimeMin = 15, CopiesContained = 24,
	},
	Gold = { 
		Order = 3, Thumbnail = "rbxassetid://119011629904797", Color = Color3.fromHex("#FFAA00"), 
		Cost = 300, CostInRobux = 21, ProductId = 3726323809,
		Rates = {Common = 15, Rare = 40, Epic = 40, Legendary = 4, Mythic = 1}, ShopDropRate = 60, ShopAmountRate = {1, 3},
		--UnlockTimeMin = 180, CopiesContained = 200,
	},
	Obsidian = { 
		Order = 4, Thumbnail = "rbxassetid://74461907425659", Color = Color3.fromHex("#B71EDD"), 
		Cost = 800, CostInRobux = 45, ProductId = 3726324548,
		Rates = {Common = 0, Rare = 25, Epic = 55, Legendary = 15, Mythic = 5}, ShopDropRate = 40, ShopAmountRate = {1, 2},
		--UnlockTimeMin = 10, CopiesContained = 186,
	},
	Diamond = { 
		Order = 5, Thumbnail = "rbxassetid://100574297197050", Color = Color3.fromHex("#0079FF"), 
		Cost = 1500, CostInRobux = 79, ProductId = 3726324899,
		Rates = {Common = 0, Rare = 5, Epic = 40, Legendary = 45, Mythic = 10}, ShopDropRate = 20, ShopAmountRate = {1, 1},
		--UnlockTimeMin = 30, CopiesContained = 450,
	},
	Secret = { 
		Order = 6, Thumbnail = "rbxassetid://90097370646092", Color = Color3.fromHex("#F7F7FF"), 
		Cost = 3000, CostInRobux = 149, ProductId = 3726325159,
		Rates = {Common = 0, Rare = 0, Epic = 10, Legendary = 40, Mythic = 50}, ShopDropRate = 10, ShopAmountRate = {1, 1},
		--UnlockTimeMin = 60, CopiesContained = 1000,
	},
} :: {[string]: ChestData}

function ChestConfig.GetChestInfo(chestName: string): ChestInfo?
	local data = ChestConfig.Chests[chestName]
	if not data then return nil end

	return {
		Name = chestName,
		Order = data.Order,
		Thumbnail = data.Thumbnail,
		Color = data.Color,
		Cost = data.Cost,
		CostInRobux = data.CostInRobux,
		ProductId = data.ProductId,
		UnlockTimeMin = data.UnlockTimeMin,
		CopiesContained = data.CopiesContained,
		Rates = data.Rates,
		ShopDropRate = data.ShopDropRate,
		ShopAmountRate = data.ShopAmountRate,
		ModelPath = game:GetService("ReplicatedStorage"):WaitForChild("Assets"):WaitForChild("Chests"):FindFirstChild(chestName)
	}
end

return ChestConfig