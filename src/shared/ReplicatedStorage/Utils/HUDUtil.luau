local HUDUtil = {}
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Player = Players.LocalPlayer

local MainGui: ScreenGui? = nil

local playerGui = Player:WaitForChild("PlayerGui")

local function getMainGui()
	if not MainGui then
		MainGui = Player:WaitForChild("PlayerGui"):WaitForChild("MainUI") :: ScreenGui
	end
	return MainGui
end

function HUDUtil:hideAllFrames()
	local MainGui = getMainGui()
	local Frames = MainGui.Frames
	for _, frame in pairs(Frames:GetChildren()) do
		if frame:IsA("Frame") then
			frame.Visible = false
		end
	end

end

local function PopOut(frame: GuiObject, position: UDim2?, duration: number?)
	
	duration = duration or 0.35
	position = position or UDim2.fromScale(0.6, 0.5)

	frame.Visible = true
	window.Visible = true
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = position

	local finalSize = frame.Size
	frame.Size = UDim2.fromScale(0, 0)

	TweenService:Create(
		frame,
		TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = finalSize }
	):Play()

end



function HUDUtil:HoverButton(btn, scale, time: number?, sound)
	if not btn or not scale then return end
	if not scale then return end
	scale = scale or 1.1
	time = time or 0.2

	local normalSize = btn.Size
	local hoverSize = UDim2.new(
		normalSize.X.Scale * scale,
		normalSize.X.Offset * scale,
		normalSize.Y.Scale * scale,
		normalSize.Y.Offset * scale
	)

	local tweenInfo = TweenInfo.new(
		time,	
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	)

	local hoverTween = TweenService:Create(btn, tweenInfo, { Size = hoverSize })
	local leaveTween = TweenService:Create(btn, tweenInfo, { Size = normalSize })

	btn.MouseEnter:Connect(function()
		hoverTween:Play()
		if sound then
			sound:Play()
		end
	end)

	btn.MouseLeave:Connect(function()
		leaveTween:Play()
		if sound then
			sound:Play()
		end
	end)
end

function HUDUtil:ToggleFrame(btn : TextButton, frame : Frame, sound :Sound, ScrollingPosition: Vector2?)
	btn.MouseButton1Click:Connect(function()
		if frame.Visible then
			
			window.Visible = false
			frame.Visible = false
			game:GetService("Lighting").Blur.Enabled = false
			return
		end

		self:hideAllFrames()
		PopOut(frame)
		if sound then sound:Play() end
		game:GetService("Lighting").Blur.Enabled = true

		if ScrollingPosition then
			local scrollingFrame = frame:FindFirstChild("ScrollingFrame", true) :: ScrollingFrame?
			if scrollingFrame then
				task.wait()
				scrollingFrame.CanvasPosition = ScrollingPosition
			end
		end
	end)
end

function HUDUtil:OpenFrame(frame: Frame, sound: Sound?, ScrollingPosition: Vector2?)
	if frame.Visible then
		frame.Visible = false
		game:GetService("Lighting").Blur.Enabled = false
		return
	end

	self:hideAllFrames()
	PopOut(frame)
	if sound then sound:Play() print("sound played") end
	game:GetService("Lighting").Blur.Enabled = true

	if ScrollingPosition then
		local scrollingFrame = frame:FindFirstChild("ScrollingFrame", true) :: ScrollingFrame?
		if scrollingFrame then
			task.wait()
			scrollingFrame.CanvasPosition = ScrollingPosition
		end
	end
end


function HUDUtil:ToggleFrameWithoutButton(frame:Frame, sound:SoundService, ScrollingPosition: Vector2?)
	if frame.Visible then
		frame.Visible = false
		window.Visible = false
		game:GetService("Lighting").Blur.Enabled = false
		return
	end

	self:hideAllFrames()
	PopOut(frame)

	if sound then 
		sound:Play() 
	end

	game:GetService("Lighting").Blur.Enabled = true

	if ScrollingPosition then
		local scrollingFrame = frame:FindFirstChild("ScrollingFrame", true) :: ScrollingFrame?
		if scrollingFrame then
			task.wait()
			scrollingFrame.CanvasPosition = ScrollingPosition
		end
	end
end


function HUDUtil:CloseFrame(frame: Frame)
	if not frame then return end
	local top = frame:FindFirstChild("Top")
	if not top then return end

	local close = (top:FindFirstChild("Main") and top.Main:FindFirstChild("Close")) or top:FindFirstChild("Close")

	if close and close:IsA("GuiButton") then
		self:HoverButton(close, 1.1, 0.25)
		close.MouseButton1Click:Connect(function()
			
			frame.Visible = false
			game.Lighting.Blur.Enabled = false
			window.Visible = false
		end)
	end
end


function HUDUtil:ScreenBlurOff()
	local Blur = game:GetService("Lighting"):FindFirstChild("Blur")
	if not Blur then return end

	if Blur.Enabled then
		Blur.Enabled = false
	end 
end

function HUDUtil:FormatTime(seconds:number)
	if seconds <= 0 then
		return {
			Days = 0,
			Hours = 0,
			Minutes = 0,
			Seconds = 0,
			Deciseconds = 0,
			Formatted = "00:00:00.0"
		}
	end

	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local mins = math.floor((seconds % 3600) / 60)
	local secs = math.floor(seconds % 60)
	local deciseconds = math.floor((seconds - math.floor(seconds)) * 10)

	return {
		Days = days,
		Hours = hours,
		Minutes = mins,
		Seconds = secs,
		Deciseconds = deciseconds,
		DaySecondsTimerFormatted = string.format("%02d:%02d:%02d:%02d", days, hours, mins, secs),
		SecondsTimerFormatted = string.format("%02d:%02d:%02d", hours, mins, secs),
		DecisecondsTimerFormatted = string.format("%02d:%02d:%02d.%d", hours, mins, secs, deciseconds)
	}
end
function HUDUtil:FormatPlayTime(seconds)
	if type(seconds) ~= "number" or seconds <= 0 then
		return "0s"
	end

	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local mins = math.floor((seconds % 3600) / 60)
	local secs = math.floor(seconds % 60)

	if days > 0 then
		return string.format("%dd %dh %dm", days, hours, mins)
	elseif hours > 0 then
		return string.format("%dh %dm %ds", hours, mins, secs)
	elseif mins > 0 then
		return string.format("%dm %ds", mins, secs)
	else
		return string.format("%ds", secs)
	end
end


return HUDUtil
