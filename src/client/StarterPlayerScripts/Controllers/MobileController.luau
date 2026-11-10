--!strict
-- Binds the current HUD to replayable actions and manages touch-only visibility.

--// Services
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local AbilityConfig = require(ReplicatedStorage.SharedModules.AbilityConfig)
local Input = require(ReplicatedStorage.Simulation.Input)

--// Modules

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainUI = PlayerGui:WaitForChild("MainGui")
local PhoneButtons = MainUI.PhoneButtons
local Hud = MainUI.HUD
local CooldownBar = Hud.CooldownBar
local AbilityBar = Hud.AbilityCooldownBar
local CooldownInfo = CooldownBar.Info
local AbilityInfo = AbilityBar.Info

--// Constants

--// Properties
local AbilityName: string? = nil
local ContextVisible = true
local IsSetup = false
local IsStarted = false

--// Types
export type MobileController = {
	IsEnabled: boolean,
	Init: () -> (),
	Setup: (self: MobileController) -> (),
	Start: (self: MobileController) -> (),
	SetVisible: (self: MobileController, isVisible: boolean) -> (),
	SetAbilityIcon: (self: MobileController, abilityName: string?) -> (),
}
--// Controller
local MobileController = {} :: MobileController

--// Helpers
local function UpdatePhoneButtonsVisibility()
	if not PhoneButtons then
		return
	end

	PhoneButtons.Visible = MobileController.IsEnabled and ContextVisible
end

local function UpdateAbilityIcon()
	if not PhoneButtons then
		return
	end

	local abilityButton = PhoneButtons.AbilityButton
	local icon = abilityButton.Icon

	local config = AbilityConfig.Abilities[AbilityName] :: AbilityConfig.AbilityConfig?

	local image = config and config.Icon
	if image then
		icon.Image = image
	end
end

local function SetupTouchGuiElements(touchGui: Instance)
	task.delay(0.1, function()
		local touchControlFrame = touchGui:WaitForChild("TouchControlFrame")
		local jumpButton = touchControlFrame:WaitForChild("JumpButton")
		if jumpButton and jumpButton:IsA("GuiObject") then
			jumpButton.Visible = false

			jumpButton:GetPropertyChangedSignal("Visible"):Connect(function()
				if jumpButton.Visible then
					jumpButton.Visible = false
				end
			end)
		end

		for _, item in touchGui:GetDescendants() do
			if item:IsA("GuiButton") then
				item:SetAttribute("NoHaptic", true)
			end
		end

		touchGui.DescendantAdded:Connect(function(item)
			if item:IsA("GuiButton") then
				item:SetAttribute("NoHaptic", true)
			end
		end)
	end)
end

local function IsMobileDevice()
	return UserInputService.PreferredInput == Enum.PreferredInput.Touch
end

local function SetupMainGui(mainGui: Instance)
	local buttons = mainGui:FindFirstChild("PhoneButtons")
	if buttons then
		for _, entry in { { "AttackButton", "Attack" }, { "AbilityButton", "Ability" }, { "JumpButton", "Jump" } } do
			local group = buttons:FindFirstChild(entry[1])
			if group then
				if group:IsA("GuiButton") then
					Input.BindButton(entry[2] :: "Attack" | "Ability" | "Jump", group)
				end
				for _, child in group:GetChildren() do
					if child:IsA("GuiButton") then
						Input.BindButton(entry[2] :: "Attack" | "Ability" | "Jump", child)
					end
				end
			end
		end
	end
	UpdatePhoneButtonsVisibility()
	UpdateAbilityIcon()

	local isMobile = IsMobileDevice()
	CooldownInfo.Visible = not isMobile
	AbilityInfo.Visible = not isMobile
end

local function UpdateEnabled()
	MobileController.IsEnabled = GuiService.TouchControlsEnabled
		and UserInputService.PreferredInput == Enum.PreferredInput.Touch
	UpdatePhoneButtonsVisibility()
end

local function HideExistingTouchGui()
	local touchGui = PlayerGui:FindFirstChild("TouchGui")
	if touchGui then
		SetupTouchGuiElements(touchGui)
	else
		-- There's a good chance that the player put a keyboard into the mobile device
		-- Or they are using a touchscreen
		local conn
		conn = PlayerGui.ChildAdded:Connect(function(obj)
			if obj.Name == "TouchGui" then
				task.wait()
				SetupTouchGuiElements(obj)
				conn:Disconnect()
			end
		end)
	end
end

--// APIs
function MobileController:Setup()
	if IsSetup then
		return
	end
	IsSetup = true

	local mainGui = PlayerGui:FindFirstChild("MainGui")
	if mainGui then
		SetupMainGui(mainGui)
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
			SetupMainGui(mainGui)
		end)
	end
	HideExistingTouchGui()
	self.IsEnabled = false
end

function MobileController:Start()
	if IsStarted then
		return
	end
	IsStarted = true

	GuiService:GetPropertyChangedSignal("TouchControlsEnabled"):Connect(UpdateEnabled)
	UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(UpdateEnabled)
	PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "MainGui" then
			SetupMainGui(child)
		elseif child.Name == "TouchGui" then
			SetupTouchGuiElements(child)
		end
	end)

	UpdateEnabled()
end

function MobileController:SetVisible(isVisible: boolean)
	ContextVisible = isVisible
	UpdatePhoneButtonsVisibility()
end

function MobileController:SetAbilityIcon(abilityName: string?)
	AbilityName = abilityName
	UpdateAbilityIcon()
end

function MobileController.Init()
	MobileController:Setup()
	MobileController:Start()
end

return MobileController
