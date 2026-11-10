--!native
--!optimize 2
local UIInteractionController = {}

-- ==========================================
-- SERVICES & VARIABLES
-- ==========================================
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local HapticService = game:GetService("HapticService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

local hoverTweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local pressTweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local frameOpenTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local frameCloseTweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local cameraTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local hudTweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.InOut)

local DEFAULT_FOV, TARGET_FOV, TARGET_BLUR = 70, 85, 15

local state = {
	uiSelectSound = nil,
	blurEffect = nil,
	activeFrame = nil,
	hudOriginalPositions = {}
}

-- ==========================================
-- HUD ANIMATION LOGIC
-- ==========================================
-- [!] Aggiunto targetFrame come parametro
local function toggleHUD(hide, targetFrame)
	local mainGui = LocalPlayer.PlayerGui:FindFirstChild("MainGui")
	local hud = mainGui and mainGui:FindFirstChild("HUD")
	if not hud then return end

	local center = Workspace.CurrentCamera.ViewportSize / 2

	for _, obj in ipairs(hud:GetChildren()) do
		if not obj:IsA("GuiObject") then continue end

		-- [!] Ora usa targetFrame invece di state.activeFrame per il controllo
		if hide and obj.Name == "CurrencyHolder" and targetFrame and targetFrame.Name == "ShopFrame" then 
			continue 
		end

		if hide then
			if not state.hudOriginalPositions[obj] then state.hudOriginalPositions[obj] = obj.Position end

			local pos = obj.AbsolutePosition + (obj.AbsoluteSize / 2)
			local dx, dy = pos.X - center.X, pos.Y - center.Y
			local orig = state.hudOriginalPositions[obj]

			local targetPos = math.abs(dx) > math.abs(dy)
				and UDim2.new(orig.X.Scale + (dx < 0 and -1 or 1), orig.X.Offset, orig.Y.Scale, orig.Y.Offset)
				or UDim2.new(orig.X.Scale, orig.X.Offset, orig.Y.Scale + (dy < 0 and -1 or 1), orig.Y.Offset)

			TweenService:Create(obj, hudTweenInfo, {Position = targetPos}):Play()
		elseif state.hudOriginalPositions[obj] then
			TweenService:Create(obj, hudTweenInfo, {Position = state.hudOriginalPositions[obj]}):Play()
		end
	end
end

-- ==========================================
-- BUTTON BEHAVIOR LOGIC
-- ==========================================
local function isInsideTemplate(obj)
	local current = obj
	while current do
		if string.match(current.Name, "Template") then return true end
		current = current.Parent
	end
	return false
end

local function bindButton(button)
	if button:GetAttribute("InteractionDisabled") then
		return
	end
	if isInsideTemplate(button) or button:GetAttribute("UIInteractionBound") then return end
	button:SetAttribute("UIInteractionBound", true)

	local uiScale = button:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", button)
	local isHovering = false

	button.MouseEnter:Connect(function()
		isHovering = true
		TweenService:Create(uiScale, hoverTweenInfo, {Scale = 1.05}):Play()
	end)

	button.MouseLeave:Connect(function()
		isHovering = false
		TweenService:Create(uiScale, hoverTweenInfo, {Scale = 1.0}):Play()
	end)

	button.MouseButton1Down:Connect(function()
		TweenService:Create(uiScale, pressTweenInfo, {Scale = 0.92}):Play()
	end)

	button.MouseButton1Up:Connect(function()
		TweenService:Create(uiScale, hoverTweenInfo, {Scale = isHovering and 1.05 or 1.0}):Play()
	end)

	button.MouseButton1Click:Connect(function()
		if state.uiSelectSound then SoundService:PlayLocalSound(state.uiSelectSound) end
		if button:GetAttribute("NoHaptic") then return end
		if HapticService:IsMotorSupported(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small) then
			print("NO HAPTIC")
			HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0.5)
			task.delay(0.1, function() HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0) end)
		end
	end)
end

-- ==========================================
-- PUBLIC FUNCTIONS
-- ==========================================
function UIInteractionController.ToggleFrame(frame, isOpening, useCameraEffects, isInternalCall)
	if useCameraEffects == nil then useCameraEffects = true end

	local isExclusive = not (CollectionService:HasTag(frame, "LobbyFrame") or CollectionService:HasTag(frame, "ArenaFrame") or CollectionService:HasTag(frame, "PopUpFrame"))

	if not isInternalCall and isOpening == false and frame:GetAttribute("ForceClosedBySystem") then isOpening = true end
	if not isInternalCall then frame:SetAttribute("ForceClosedBySystem", nil) end

	local uiScale = frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", frame)
	local camera = Workspace.CurrentCamera

	if isOpening then
		if isExclusive then
			-- [!] Passiamo frame a toggleHUD
			if not state.activeFrame then toggleHUD(true, frame) end
			if state.activeFrame and state.activeFrame ~= frame then
				state.activeFrame:SetAttribute("ForceClosedBySystem", true)
				UIInteractionController.ToggleFrame(state.activeFrame, false, false, true)
			end
			state.activeFrame = frame
		end

		frame.Visible = true
		uiScale.Scale = 0
		TweenService:Create(uiScale, frameOpenTweenInfo, {Scale = 1}):Play()

		if useCameraEffects then
			TweenService:Create(camera, cameraTweenInfo, {FieldOfView = TARGET_FOV}):Play()
			if state.blurEffect then TweenService:Create(state.blurEffect, cameraTweenInfo, {Size = TARGET_BLUR}):Play() end
		end
	else
		if isExclusive and state.activeFrame == frame then
			state.activeFrame = nil
			-- [!] Passiamo frame a toggleHUD
			toggleHUD(false, frame)
		end

		local closeTween = TweenService:Create(uiScale, frameCloseTweenInfo, {Scale = 0})
		closeTween:Play()
		closeTween.Completed:Once(function() if uiScale.Scale < 0.1 then frame.Visible = false end end)

		if useCameraEffects then
			TweenService:Create(camera, cameraTweenInfo, {FieldOfView = DEFAULT_FOV}):Play()
			if state.blurEffect then TweenService:Create(state.blurEffect, cameraTweenInfo, {Size = 0}):Play() end
		end
	end
end

function UIInteractionController.CloseActiveFrame()
	if state.activeFrame then
		state.activeFrame:SetAttribute("ForceClosedBySystem", true)
		UIInteractionController.ToggleFrame(state.activeFrame, false, true, true)
	end
end

-- ==========================================
-- INIT
-- ==========================================
function UIInteractionController.Init()
	state.uiSelectSound = SoundService:WaitForChild("SFX"):WaitForChild("UISelect")

	state.blurEffect = Lighting:FindFirstChild("UIBlurEffect") or Instance.new("BlurEffect", Lighting)
	state.blurEffect.Name, state.blurEffect.Size = "UIBlurEffect", 0

	local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

	for _, descendant in ipairs(PlayerGui:GetDescendants()) do
		if descendant:IsA("GuiButton") then bindButton(descendant) end
	end

	PlayerGui.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("GuiButton") then task.defer(bindButton, descendant) end
	end)
end

return UIInteractionController
