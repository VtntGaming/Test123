local Misc = require(game.ReplicatedStorage.Module.VFXManager.VFXUtils.Misc)
local module = {}

module.TextOnHead = function(plr, te, textt, speed)
	local forcera = game.ReplicatedStorage.Asset.Player.ForceRate:Clone()
	forcera.Parent = plr.Character.HumanoidRootPart

	local forcetext = game.ReplicatedStorage.Asset.Text[te]:Clone()
	forcetext.Parent = forcera
	forcetext.Text = textt

	Misc.Debris(forcetext, 1)
	game:GetService("TweenService"):Create(forcetext, TweenInfo.new(.5/speed, Enum.EasingStyle.Back), {Position = UDim2.new(0,0,0.1,0)}):Play()
	task.delay(.3/speed, function() 
		game:GetService("TweenService"):Create(forcetext, TweenInfo.new(.2/speed, Enum.EasingStyle.Linear), {TextTransparency = 1}):Play() 
		game:GetService("TweenService"):Create(forcetext.UIStroke, TweenInfo.new(.2/speed, Enum.EasingStyle.Linear), {Transparency = 1}):Play() 
	end)
end

module.TextOnTop = function(plr, tipe, text, duration, hidespeed)
	local textl = game.ReplicatedStorage.Asset.Text[tipe]:Clone()
	textl.Parent = plr.PlayerGui.PlayerGui.TB
	textl.Text = text
	textl.TextTransparency = 1
	game:GetService("TweenService"):Create(textl, TweenInfo.new(hidespeed, Enum.EasingStyle.Linear), {TextTransparency = 0}):Play()
	if textl:FindFirstChildOfClass("UIStroke") then
		textl:FindFirstChildOfClass("UIStroke").Transparency = 1
		game:GetService("TweenService"):Create(textl:FindFirstChildOfClass("UIStroke"), TweenInfo.new(hidespeed, Enum.EasingStyle.Linear), {Transparency = 0}):Play()
	end

	task.delay(duration, function()
		Misc.Debris(textl, hidespeed)

		game:GetService("TweenService"):Create(textl, TweenInfo.new(hidespeed, Enum.EasingStyle.Linear), {TextTransparency = 1}):Play()
		if textl:FindFirstChildOfClass("UIStroke") then
			game:GetService("TweenService"):Create(textl:FindFirstChildOfClass("UIStroke"), TweenInfo.new(hidespeed, Enum.EasingStyle.Linear), {Transparency = 1}):Play()
		end
	end)
end


return module
