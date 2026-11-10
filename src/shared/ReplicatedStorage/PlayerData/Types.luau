--!strict
-- Defines the scalar and serialized inventory values exposed by the PlayerData interface.

export type InventoryKey = "OwnedWeapons" | "OwnedAbilities" | "OwnedChests"

export type Value = boolean | number | string
export type Values = { [string]: Value? }

return table.freeze({})
