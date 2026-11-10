--!strict
local GhostItem = require(script.Parent.GhostItem)

export type ForgeStates = {
	ActiveSlots: { [number]: string? },
	InventoryCounts: { [string]: number },
	DragSource: number?,
	GhostItem: GhostItem.GhostItem?,
	IsInZone: boolean,
	CanForge: boolean,
	Connections: { RBXScriptConnection },
	RateLabels: { [string]: TextLabel },
	ForgeAnimThread: thread?,
	ForgeResultThread: thread?,
	ThreeSlotStatus: {
		ScaleSpeed: number,
		RotationSpeed: number,
		ScaleMultiplier: number,
		IsAnimating: boolean,
	}
}

local ForgeStates: ForgeStates = {
	ActiveSlots = { nil, nil, nil },
	InventoryCounts = {},
	DragSource = nil,
	GhostItem = nil,
	IsInZone = false,
	CanForge = false,
	Connections = {},
	RateLabels = {},
	ThreeSlotStatus = {
		ScaleSpeed = 1,
		RotationSpeed = 1,
		ScaleMultiplier = 1,
		IsAnimating = false
	}
}

return ForgeStates