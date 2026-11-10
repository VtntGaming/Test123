--!strict

export type AbilityPreviewContext = {
	Character: Model?,
	Root: BasePart?,
	Weapon: Model?,
	Animator: Animator?,
	LastWeaponOriginScale: number,
	SpawnDashHologram: (character: Model, progress: number?) -> (),
}

export type AbilityPreviewModule = {
	ShowcaseAbility: ((context: AbilityPreviewContext) -> ())?,
	StopPreview: (() -> ())?,
	StopShrinkPreview: (() -> ())?,
	StopTimeStopPreview: (() -> ())?,
	StopBigWeaponPreview: (() -> ())?,
	ApplyCharacterScale: ((character: Model, scale: number) -> ())?,
}

local AbilityPreviewTypes = {} :: {
	AbilityPreviewContext: AbilityPreviewContext,
	AbilityPreviewModule: AbilityPreviewModule,
}

AbilityPreviewTypes.AbilityPreviewContext = {} :: AbilityPreviewContext
AbilityPreviewTypes.AbilityPreviewModule = {} :: AbilityPreviewModule

return AbilityPreviewTypes
