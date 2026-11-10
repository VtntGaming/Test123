local module = {}

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Parentt = workspace.visual

-- SAFE CALL
local function SafeCall(fn)
	local ok, err = pcall(fn)
	if not ok then
		warn("[Misc]", err)
	end
end

-- ShowGui
module.ShowGui = function(gui, timee)
	SafeCall(function()
		for _, df in pairs(gui:GetDescendants()) do
			if df:IsA("ImageButton") then
				local oldd = df.ImageTransparency

				df.ImageTransparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {ImageTransparency = oldd}):Play()
			end

			if df:IsA("ImageLabel") then
				local oldd = df.ImageTransparency

				df.ImageTransparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {ImageTransparency = oldd}):Play()
			end

			if df:IsA("Frame") then
				local oldd = df.Transparency

				df.Transparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {Transparency = oldd}):Play()
			end

			if df:IsA("TextLabel") then
				local oldd = df.TextTransparency

				df.TextTransparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {TextTransparency = oldd}):Play()
			end

			if df:IsA("UIStroke") then
				local oldd = df.Transparency

				df.Transparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {Transparency = oldd}):Play()
			end
		end
	end)
end

-- HideGui
module.HideGui = function(gui, timee)
	SafeCall(function()
		for _, df in pairs(gui:GetDescendants()) do
			if df:IsA("ImageButton") then
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {ImageTransparency = 1}):Play()
			end

			if df:IsA("ImageLabel") then
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {ImageTransparency = 1}):Play()
			end

			if df:IsA("Frame") then
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {Transparency = 1}):Play()
			end

			if df:IsA("TextLabel") then
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {TextTransparency = 1}):Play()
			end

			if df:IsA("UIStroke") then
				game:GetService("TweenService"):Create(df, TweenInfo.new(timee, Enum.EasingStyle.Quad), {Transparency = 1}):Play()
			end
		end
	end)
end

return module
