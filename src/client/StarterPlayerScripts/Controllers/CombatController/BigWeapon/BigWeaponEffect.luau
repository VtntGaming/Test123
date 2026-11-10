--!strict
-- Presents the confirmed growth sound; shared simulation owns weapon dimensions and scale timing.
local SoundService = game:GetService("SoundService")
local Swing = SoundService.SFX.heavyswordswing
export type BigWeaponEffect = {
	Init: (unknown?) -> (),
	Start: (unknown, unknown, unknown) -> (),
	End: (Player) -> (),
	Impact: (unknown, unknown, unknown) -> (),
}
local BigWeaponEffect: BigWeaponEffect = {} :: BigWeaponEffect
function BigWeaponEffect.Start(player, character, data)
	if
		typeof(player) ~= "Instance"
		or not player:IsA("Player")
		or typeof(character) ~= "Instance"
		or not character:IsA("Model")
		or player.Character ~= character
	then
		return
	end
	Swing:Play()
end
function BigWeaponEffect.End(player) end
function BigWeaponEffect.Impact(player, center, radius) end
function BigWeaponEffect.Init(shakeFn) end
return BigWeaponEffect
