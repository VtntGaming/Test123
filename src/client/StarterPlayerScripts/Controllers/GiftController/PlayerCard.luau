--!strict
-- Presents player card behavior using logical Player data access.
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local Signal = require(ReplicatedStorage.Utils.Signal)

--// Types
export type PlayerCard = {
	Player: Player,
	Parent: Instance,
	Template: Frame,
	Frame: Frame?,
	Activated: Signal.Signal<string>,
	Connections: {RBXScriptConnection},
	DataConnection: PlayerData.Connection?,
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
	local self = setmetatable({} :: any, PlayerCard) :: PlayerCard
	self.Player = player
	self.Parent = parent
	self.Template = template
	self.Frame = nil
	self.Activated = Signal.new()
	self.Connections = {}
	self.DataConnection = nil
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
		giftButton.Active = PlayerData.Get(self.Player, "DataLoaded") == true
	end
	updateReady()
	self.DataConnection = PlayerData.Observe(self.Player, "DataLoaded", updateReady)

	table.insert(self.Connections, giftButton.Activated:Connect(function()
		if not self.IsDestroyed and PlayerData.Get(self.Player, "DataLoaded") == true then
			activated:Fire(playerName)
		end
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

function PlayerCard.Destroy(self: PlayerCard)
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true

	for _, connection in ipairs(self.Connections) do
		connection:Disconnect()
	end

	if self.DataConnection then
		self.DataConnection:Disconnect()
	end
	self.DataConnection = nil
	self.Activated:Destroy()

	local frame = self.Frame
	if frame then
		frame:Destroy()
	end

	self.Frame = nil
	table.clear(self.Connections)
end

return PlayerCard
