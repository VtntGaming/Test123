--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Signal = require(ReplicatedStorage.Utils.Signal)

--// Types
export type PlayerCard = {
	Player: Player,
	Parent: Instance,
	Template: Frame,
	Frame: Frame?,
	Activated: Signal.Signal<string>,
	Connections: {RBXScriptConnection},
	IsDestroyed: boolean,
	new: (player: Player, parent: Instance, template: Frame) -> PlayerCard,
	Setup: (self: PlayerCard) -> (),
	Start: (self: PlayerCard) -> (),
	Destroy: (self: PlayerCard) -> (),
}

--// Controller
local PlayerCard = {}
PlayerCard.__index = PlayerCard

--// APIs
function PlayerCard.new(player: Player, parent: Instance, template: Frame): PlayerCard
	local self = setmetatable({}, PlayerCard) :: PlayerCard
	self.Player = player
	self.Parent = parent
	self.Template = template
	self.Frame = nil
	self.Activated = Signal.new()
	self.Connections = {}
	self.IsDestroyed = false
	self:Setup()
	self:Start()

	return self
end

function PlayerCard:Setup()
	local frame = self.Template:Clone()
	frame.Name = self.Player.Name
	frame.Visible = true
	frame.Parent = self.Parent
	self.Frame = frame

	local container = frame:WaitForChild("Container")
	local playerName = container:WaitForChild("PlayerName") :: TextLabel
	playerName.Text = self.Player.Name
end

function PlayerCard:Start()
	local frame = self.Frame
	assert(frame, "Player card must be set up before starting")

	local container = frame:WaitForChild("Container")
	local imageContainer = container:WaitForChild("ImageContainer")
	local imageLabel = imageContainer:WaitForChild("ImageLabel") :: ImageLabel
	local giftButton = container:WaitForChild("GiftButton") :: GuiButton
	local activated = self.Activated
	local userId, playerName = self.Player.UserId, self.Player.Name
	local function updateReady()
		giftButton.Active = self.Player:GetAttribute("DataLoaded") == true
	end
	updateReady()
	table.insert(self.Connections, self.Player:GetAttributeChangedSignal("DataLoaded"):Connect(updateReady))

	table.insert(self.Connections, giftButton.Activated:Connect(function()
		if not self.IsDestroyed and self.Player:GetAttribute("DataLoaded") == true then activated:Fire(playerName) end
	end))

	task.spawn(function()
		local success, image = pcall(function()
			return Players:GetUserThumbnailAsync(
				userId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size420x420
			)
		end)

		if success then
			if not self.IsDestroyed and frame.Parent then
				imageLabel.Image = image
			end
		else
			if not self.IsDestroyed then warn(`Failed to load gift recipient thumbnail for {playerName}: {image}`) end
		end
	end)
end

function PlayerCard:Destroy()
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true

	for _, connection in ipairs(self.Connections) do
		connection:Disconnect()
	end

	self.Activated:Destroy()

	local frame = self.Frame
	if frame then
		frame:Destroy()
	end

	self.Frame = nil
	table.clear(self.Connections)
end

return PlayerCard
