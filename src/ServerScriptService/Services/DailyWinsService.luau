--!strict
-- Tracks daily wins and equips a reward tool that consumes the daily claim only when opened.

--// Services
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)
local Config = require(ReplicatedStorage.SharedModules.DailyChestConfig)
local ChestCatalog = require(ReplicatedStorage.SharedModules.ChestCatalog)
local ChestService = require(script.Parent.ChestService)
local Runtime = require(script.Parent.Helper.ShopRuntime)

--// References
local Events = ReplicatedStorage.Events

--// Constants
local DAY_SECONDS = 86400
local REQUEST_COOLDOWN = 0

--// Properties
local Initialized = false
local Started = false
local Remote: RemoteEvent
local Connections: { [Player]: { RBXScriptConnection } } = {}
local Tools: { [Player]: Tool } = {}
local LastMatchIds: { [Player]: number } = {}
local NextRequests: { [Player]: number } = {}

--// Types
export type DailyWinsService = {
    Init: () -> (),
    Setup: (self: DailyWinsService) -> (),
    Start: (self: DailyWinsService) -> (),
    Refresh: (player: Player) -> (),
    RecordWin: (player: Player, matchId: number) -> (),
    Claim: (player: Player) -> (boolean, string?),
    Equip: (player: Player) -> (boolean, string?),
}

--// Service
local DailyWinsService = {} :: DailyWinsService

local function GetDayStart(): number
    return math.floor(os.time() / DAY_SECONDS) * DAY_SECONDS
end

local function GetWins(player: Player): number
    local wins = player:GetAttribute("DailyWins")
    if type(wins) ~= "number" or wins ~= wins or wins < 0 or wins >= math.huge then
        return 0
    end
    return math.floor(wins)
end

local function RemoveTool(player: Player)
    local tool = Tools[player]
    Tools[player] = nil
    if tool then
        tool:Destroy()
    end
end

local function CheckEligibility(player: Player): (boolean, string?)
    if not Runtime.Ready(player) then
        return false, "DataNotLoaded"
    end
    DailyWinsService.Refresh(player)
    if player:GetAttribute("DailyWinsClaimed") == true then
        return false, "AlreadyClaimed"
    end
    if GetWins(player) < Config.WinsRequired then
        return false, "NotEnoughWins"
    end
    return true, nil
end

local function SendStatus(player: Player, status: string)
    if player.Parent == Players then
        Remote:FireClient(player, status)
    end
end

local function WatchPlayer(player: Player)
    if Connections[player] then
        return
    end
    Connections[player] = {
        player:GetAttributeChangedSignal("DataLoaded"):Connect(function()
            if Runtime.Ready(player) then
                DailyWinsService.Refresh(player)
            else
                RemoveTool(player)
            end
        end),
        player.CharacterAdded:Connect(function()
            RemoveTool(player)
        end),
    }
    DailyWinsService.Refresh(player)
end

--// APIs
function DailyWinsService.Refresh(player)
    if not Runtime.Ready(player) then
        return
    end
    local dayStart = GetDayStart()
    local timestamp = player:GetAttribute("DailyWinsTimestamp")
    if
        type(timestamp) ~= "number"
        or timestamp ~= timestamp
        or timestamp < dayStart
        or timestamp >= dayStart + DAY_SECONDS
    then
        -- No yields: profile snapshots always see a consistent day's progress and claim state.
        player:SetAttribute("DailyWins", 0)
        player:SetAttribute("DailyWinsClaimed", false)
        player:SetAttribute("DailyWinsTimestamp", dayStart)
    else
        player:SetAttribute("DailyWins", GetWins(player))
    end
    AnalyticsService.RecordDailyWins(player, dayStart, GetWins(player), Config.WinsRequired, player:GetAttribute("DailyWinsClaimed") == true)
end

function DailyWinsService.RecordWin(player, matchId)
    if not Runtime.Ready(player) or matchId <= 0 or matchId % 1 ~= 0 or matchId >= math.huge then
        return
    end
    if matchId <= (LastMatchIds[player] or 0) then
        return
    end
    DailyWinsService.Refresh(player)
    LastMatchIds[player] = matchId
    player:SetAttribute("DailyWins", GetWins(player) + 1)
    AnalyticsService.RecordDailyWins(player, GetDayStart(), GetWins(player), Config.WinsRequired, player:GetAttribute("DailyWinsClaimed") == true)
end

function DailyWinsService.Claim(player)
    return Runtime.Run(player, "DailyWinsClaim", function()
        local eligible, reason = CheckEligibility(player)
        if not eligible then
            return false, reason
        end
        local tool = Tools[player]
        if not tool or not player.Character or tool.Parent ~= player.Character then
            return false, "EquipFirst"
        end
        local opened, openingReason = ChestService.OpenRewardChest(player, Config.ChestType, {
            Check = function()
                return CheckEligibility(player)
            end,
            Consume = function()
                player:SetAttribute("DailyWinsClaimed", true)
                AnalyticsService.RecordDailyWins(player, player:GetAttribute("DailyWinsTimestamp") :: number, GetWins(player), Config.WinsRequired, true)
            end,
        }, tool)
        if player:GetAttribute("DailyWinsClaimed") == true then
            RemoveTool(player)
        end
        return opened, if openingReason == "SavePending" then "OpeningSavePending" else openingReason
    end)
end

function DailyWinsService.Equip(player)
    local canEquip, reason = ChestService.CanEquip(player)
    if not canEquip then
        return false, reason
    end
    DailyWinsService.Refresh(player)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local backpack = player:FindFirstChildOfClass("Backpack")
    if not character or not humanoid or not backpack then
        return false, "CharacterUnavailable"
    end
    local tool = Tools[player]
    if tool and tool.Parent == character then
        humanoid:UnequipTools()
        return true, "Unequipped"
    end
    if not tool or tool.Parent == nil then
        local createdTool = ChestService.CreateRewardTool(player, Config.ChestType, function(activatedTool: Tool)
            if Tools[player] ~= activatedTool or activatedTool.Parent ~= player.Character then
                return
            end
            local opened, claimReason = DailyWinsService.Claim(player)
            SendStatus(player, if opened then "Claimed" else claimReason or "RetryLater")
        end)
        if not createdTool then
            return false, "InvalidChest"
        end
        Tools[player] = createdTool
        tool = createdTool
    end
    if not tool then
        return false, "InvalidChest"
    end
    tool.Parent = backpack
    humanoid:EquipTool(tool)
    return true, "Equipped"
end

function DailyWinsService:Setup()
    assert(
        Config.WinsRequired > 0 and Config.WinsRequired < math.huge and Config.WinsRequired % 1 == 0,
        "DailyChestConfig.WinsRequired must be a positive integer"
    )
    assert(ChestCatalog.Get(Config.ChestType), "DailyChestConfig.ChestType must identify a configured chest")
    local existing = Events:FindFirstChild("DailyWinsEvent")
    if existing then
        assert(existing:IsA("RemoteEvent"), "DailyWinsEvent must be a RemoteEvent")
        Remote = existing
    else
        Remote = Instance.new("RemoteEvent")
        Remote.Name = "DailyWinsEvent"
        Remote.Parent = Events
    end
end

function DailyWinsService:Start()
    if Started then
        return
    end
    Started = true
    Remote.OnServerEvent:Connect(function(player: Player, action: unknown)
        if action ~= "Equip" then
            return
        end
        local now = os.clock()
        if now < (NextRequests[player] or 0) then
            return
        end
        NextRequests[player] = now + REQUEST_COOLDOWN
        local equipped, reason = DailyWinsService.Equip(player)
        SendStatus(player, reason or (if equipped then "Equipped" else "RetryLater"))
    end)
    Players.PlayerAdded:Connect(WatchPlayer)
    Players.PlayerRemoving:Connect(function(player: Player)
        local connections = Connections[player]
        if connections then
            for _, connection in connections do
                connection:Disconnect()
            end
        end
        RemoveTool(player)
        Connections[player], LastMatchIds[player], NextRequests[player] = nil, nil, nil
    end)
    for _, player in Players:GetPlayers() do
        WatchPlayer(player)
    end
    task.spawn(function()
        local dayStart = GetDayStart()
        while true do
            task.wait(1)
            local currentDay = GetDayStart()
            if currentDay ~= dayStart then
                dayStart = currentDay
                for _, player in Players:GetPlayers() do
                    DailyWinsService.Refresh(player)
                end
            end
        end
    end)
end

function DailyWinsService.Init()
    if Initialized then
        return
    end
    DailyWinsService:Setup()
    Initialized = true
    DailyWinsService:Start()
end

return DailyWinsService
