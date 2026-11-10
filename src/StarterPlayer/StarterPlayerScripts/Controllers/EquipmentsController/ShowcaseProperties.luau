--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
--// Constants
local WEAPON_CAMERA_LEFT_OFFSET = 2.5

--// Properties
local EquipmentShowcase = ReplicatedStorage.Assets.EquipmentShowcase:Clone()

--// Types
export type ShowcaseProperties = {
    TargetRotation: number,
    CurrentRotation: number,
    InstantRotationChange: number,
    LastEnabled: number,
    CameraFollowCharacter: boolean,
    UseSmoothCameraAnimation: boolean,
    CameraOffset: Vector3,
    CustomFollowPosition: Vector3?,
    CharacterVectorOffset: Vector3,
    CurrentParallax: Vector2,
    CharacterScale: number,
    CharacterTransparency: number,
    CurrentCharScale: number,
    CurrentCharTrans: number,
    CurrentLeftOffset: number,
    ExistingWeaponTrack: AnimationTrack?,
    ExistingRunningTrack: AnimationTrack?,
    ExistingAttackTrack: AnimationTrack?,
    LastWeaponOriginScale: number,
    TimeStopPreviewActive: boolean,
    ShrinkPreviewCharacter: Model?,
    AbilityShowcaseThread: thread?,
    CharacterCFrame: CFrame,
    EquipmentShowcase: typeof(EquipmentShowcase),
}

--// Properties
local ShowcaseProperties = {
    TargetRotation = 0,
    CurrentRotation = 0,
    InstantRotationChange = 0,
    LastEnabled = 0,
    CameraFollowCharacter = false,
    UseSmoothCameraAnimation = false,
    CameraOffset = Vector3.zero,
    CustomFollowPosition = nil,
    CharacterVectorOffset = Vector3.zero,
    CurrentParallax = Vector2.zero,
    CharacterScale = 1,
    CharacterTransparency = 0,
    CurrentCharScale = 1,
    CurrentCharTrans = 0,
    CurrentLeftOffset = WEAPON_CAMERA_LEFT_OFFSET,
    ExistingWeaponTrack = nil,
    ExistingRunningTrack = nil,
    ExistingAttackTrack = nil,
    LastWeaponOriginScale = 1,
    TimeStopPreviewActive = false,
    ShrinkPreviewCharacter = nil,
    AbilityShowcaseThread = nil,
    CharacterCFrame = CFrame.new(),
    EquipmentShowcase = EquipmentShowcase,
} :: ShowcaseProperties

return ShowcaseProperties