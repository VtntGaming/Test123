--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

local LocalPlayer = Players.LocalPlayer
local MainGui = LocalPlayer.PlayerGui:WaitForChild("MainGui")
local ForgeFrame = MainGui:WaitForChild("ForgeFrame")
local Result = ForgeFrame:WaitForChild("Result")
local Icon = Result:WaitForChild("Icon")
local Title = Result:WaitForChild("Title")
local Rarity = Result:WaitForChild("Rarity")
local Effect = Result:WaitForChild("Effect")
local EffectScale = Effect:WaitForChild("UIScale")
local IconScale = Icon.UIScale
local TitleScale = Title.UIScale
local RarityScale = Rarity.UIScale

local DISPLAY_DURATION = 3
local activeTween: Tween? = nil

export type ForgeResult = {
	ShowResult: (itemName: string) -> (),
}

local ForgeResult = {} :: ForgeResult

function ForgeResult.ShowResult(itemName: string)
	local weaponInfo = WeaponConfig.GetWeaponInfo(itemName)
	assert(weaponInfo, `No weapon info exists for "{itemName}"`)

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	Icon.Image = weaponInfo.Icon
	Title.Text = weaponInfo.DisplayName
	Title.TextColor3 = weaponInfo.RarityColor
	Rarity.Text = weaponInfo.Rarity
	Rarity.TextColor3 = weaponInfo.RarityColor
	EffectScale.Scale = 0.75
	Result.Visible = true

	TweenUtils.PlayTweenSequence({
		TweenService:Create(EffectScale, TweenInfo.new(0), {
			Scale = 0
		}),
		TweenService:Create(IconScale, TweenInfo.new(0), {
			Scale = 0
		}),
		TweenService:Create(TitleScale, TweenInfo.new(0), {
			Scale = 0
		}),      
		TweenService:Create(RarityScale, TweenInfo.new(0), {
			Scale = 0
		}),      
		true,  
		TweenService:Create(EffectScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1
		}),
        true,
		TweenService:Create(IconScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1
		}),
        0.05,
        true,
		TweenService:Create(TitleScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1
		}),
        0.05,
		TweenService:Create(RarityScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1
		}),
	}, true)
	task.wait(DISPLAY_DURATION)
	TweenUtils.PlayTweenSequence({
        true,
		TweenService:Create(EffectScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Scale = 0.0
		}),
        true,
        TweenService:Create(IconScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Scale = 0.0
		}),
        true,
        TweenService:Create(TitleScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Scale = 0.0
		}),
        TweenService:Create(RarityScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Scale = 0.0
		}),
	}, true)

	Result.Visible = false
	EffectScale.Scale = 1
end

return ForgeResult