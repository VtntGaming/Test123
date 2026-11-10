--!strict
-- Owns daily chest progress indicators, equip input and opening notifications.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

--// Modules
local ChestCatalog = require(ReplicatedStorage.SharedModules.ChestCatalog)
local DailyChestConfig = require(ReplicatedStorage.SharedModules.DailyChestConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local MainUI = LocalPlayer.PlayerGui:WaitForChild("MainGui")
local DailyChestFrame = MainUI.HUD.Hotbar.DailyChest
local ChestRef = DailyChestFrame.Wins.WinTemplate
local DailyChestButton = MainUI.HUD.Hotbar.DailyChest
local NotificationFrame = DailyChestFrame.Notify

--// Constants
local DAILY_CHEST_KEYCODE = Enum.KeyCode.C
local DAY_SECONDS = 86400
local WIN_COLOR = Color3.fromRGB(255, 251, 0)
local MISSING_COLOR = Color3.fromRGB(255, 255, 255)
local DAILY_MESSAGES: { [string]: string } = {
    AlreadyClaimed = "Come back tomorrow!",
    DataNotLoaded = "Wait a bit...",
    OpeningBlocked = "Can't open right now.",
    CharacterUnavailable = "Can't open right now.",
    OpeningPending = "Can't open right now.",
    Cooldown = "Wait a bit...",
    ChestRecoveryRequired = "Wait a bit...",
    InvalidChest = "Can't open right now.",
    Busy = "Can't open right now.",
    OpeningSavePending = "You daily claimed!",
    EquipFirst = "Equip to open!",
    RewardUnavailable = "Can't open right now.",
    TimedOut = "Something happened...",
}

--// Properties
local WinsFrames: { typeof(ChestRef) } = {}
local SetupComplete = false
local Started = false
local DailyRemote: RemoteEvent? = nil
local LastClaimRequest = -math.huge
local LastDailyWins: number? = nil
local LastDailyTimestamp: number? = nil
local ChestTween: Tween?
local ChestTweenOriginalPosition: UDim2?
local NotifyThread: thread?
--// Types
export type DailyChest = {
    Setup: (self: DailyChest) -> (),
    Start: (self: DailyChest) -> (),
}

--// Controller
local DailyChest = {} :: DailyChest
local function ShowNotification(notifyType: string, message: string)
    local notifyLabel = NotificationFrame.Notify
    notifyLabel.Text = string.upper(message)

    if NotifyThread then
        task.cancel(NotifyThread)
    end

    NotifyThread = TweenUtils.PlayTweenSequence({
        function()
            notifyLabel.Visible = true
        end,
        TweenService:Create(notifyLabel, TweenInfo.new(0), {TextTransparency = 0}),
        TweenService:Create(notifyLabel.UIStroke, TweenInfo.new(0), {Transparency = 0}),
        TweenService:Create(notifyLabel.UIScale, TweenInfo.new(0), {Scale = 0}),
        TweenService:Create(notifyLabel.UIScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
        1.5,
        true,
        TweenService:Create(notifyLabel, TweenInfo.new(1, Enum.EasingStyle.Linear), {TextTransparency = 1}),
        TweenService:Create(notifyLabel.UIStroke, TweenInfo.new(1, Enum.EasingStyle.Linear), {Transparency = 1}),
        function()
            notifyLabel.Visible = false
        end,
    })
end

local function UpdateTimer()
    local now = Workspace:GetServerTimeNow()
    local timestamp = LocalPlayer:GetAttribute("DailyWinsTimestamp")
    local dayStart = if type(timestamp) == "number" and timestamp > 0 then timestamp else now
    local resetAt = (math.floor(dayStart / DAY_SECONDS) + 1) * DAY_SECONDS
    local remaining = math.max(0, math.ceil(resetAt - now))
    DailyChestButton.Timer.Text.Text = string.format("%02d:%02d:%02d", remaining // 3600, (remaining % 3600) // 60, remaining % 60)
end

local function UpdateDailyChest()
    local wins = LocalPlayer:GetAttribute("DailyWins")
    local timestamp = LocalPlayer:GetAttribute("DailyWinsTimestamp")
    local claimed = LocalPlayer:GetAttribute("DailyWinsClaimed") == true
    local dailyWins = if type(wins) == "number" then wins else 0
    for index, frame in WinsFrames do
        local isFinished = index <= dailyWins
        frame.Completed.Visible = isFinished
        
        if index <= dailyWins then
            -- frame.BackgroundColor3 = WIN_COLOR
            -- frame.BackgroundTransparency = 0.1
        else
            -- frame.BackgroundColor3 = MISSING_COLOR
            -- frame.BackgroundTransparency = 0.35
        end
        frame.Visible = not claimed
    end
    DailyChestButton.Chest.Hover.ImageTransparency = if claimed then 0.5 else 1
    DailyChestButton.Chest.Claim.ImageTransparency = if claimed then 0 else 1
    DailyChestButton.Timer.Visible = claimed
    if LocalPlayer:GetAttribute("DataLoaded") ~= true or type(timestamp) ~= "number" or timestamp <= 0 then
        return
    end
    if not claimed then
        if dailyWins >= DailyChestConfig.WinsRequired then
            if
                LastDailyWins == nil
                or LastDailyTimestamp ~= timestamp
                or LastDailyWins < DailyChestConfig.WinsRequired
            then
                ShowNotification(
                    "Success",
                    "Claim your chest!"
                )
                if not ChestTween then
                    local icon = DailyChestButton.Chest.Icon
                    local pos = icon.Position
                    local tween = TweenService:Create(icon, TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
                        Position = UDim2.new(pos.X.Scale, pos.X.Offset, pos.Y.Scale-0.1, pos.Y.Offset)
                    })
                    tween:Play()
                    ChestTween = tween
                    ChestTweenOriginalPosition = pos
                end
            end
        elseif LastDailyWins ~= nil and LastDailyTimestamp == timestamp and dailyWins > LastDailyWins then
            local remains = DailyChestConfig.WinsRequired - dailyWins
            ShowNotification(
                "Info",
                `Keep going, {remains} more!`
            )
        end
    else
        if ChestTween then
            ChestTween:Cancel()
            ChestTween = nil
            if ChestTweenOriginalPosition then
                DailyChestButton.Chest.Icon.Position = ChestTweenOriginalPosition
                ChestTweenOriginalPosition = nil
            end
        end
    end
    LastDailyWins, LastDailyTimestamp = dailyWins, timestamp
end

local function EquipDailyChest()
    if os.clock() - LastClaimRequest < 0 then
        return
    end
    LastClaimRequest = os.clock()
    local remote = DailyRemote
    if not remote or LocalPlayer:GetAttribute("DataLoaded") ~= true then
        ShowNotification("Info", DAILY_MESSAGES.DataNotLoaded)
        return
    end
    
    local wins = LocalPlayer:GetAttribute("DailyWins")
    local remaining =
        math.max(0, DailyChestConfig.WinsRequired - (if type(wins) == "number" then wins else 0))
        
    if LocalPlayer:GetAttribute("DailyWinsClaimed") then
            ShowNotification("Info", DAILY_MESSAGES.AlreadyClaimed)
            return    
    elseif remaining > 0 then
        ShowNotification(
            "Info",
            `Win {remaining} more match{if remaining == 1 then "" else "es"}!`
        )
        return
    end
    remote:FireServer("Equip")
end

function DailyChest:Setup()
    if SetupComplete then
        return
    end
    SetupComplete = true
    local template = DailyChestButton.Wins.WinTemplate
    template.Visible = false
    for index = 1, DailyChestConfig.WinsRequired do
        local clone = template:Clone()
        clone.Name = `Win{index}`
        clone.LayoutOrder = index
        clone.Visible = true
        local stroke = clone:FindFirstChildWhichIsA("UIStroke")
        if stroke then
            stroke.Enabled = true
        end
        clone.Parent = template.Parent
        WinsFrames[index] = clone
    end
    local info = ChestCatalog.Get(DailyChestConfig.ChestType)
    if info then
        -- DailyChestButton.Chest.Icon.Image = info.Thumbnail
    end
end

function DailyChest:Start()
    if Started then
        return
    end
    Started = true
    UpdateTimer()
    task.spawn(function()
        while DailyChestButton.Parent do
            task.wait(1)
            if not DailyChestButton.Parent then break end
            UpdateTimer()
        end
    end)
    do -- Daily chest button
        DailyChestButton.Chest.Activated:Connect(EquipDailyChest)
        for _, attribute in { "DailyWins", "DailyWinsTimestamp", "DailyWinsClaimed", "DataLoaded" } do
            LocalPlayer:GetAttributeChangedSignal(attribute):Connect(function()
                task.defer(UpdateDailyChest)
            end)
        end
        UpdateDailyChest()
        local uiScale = DailyChestButton.UIScale :: UIScale
        local lastHold: number? = nil
        UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if
                input.KeyCode == DAILY_CHEST_KEYCODE
                and not gameProcessed
                and not UserInputService:GetFocusedTextBox()
            then
                TweenService
                    :Create(
                        uiScale,
                        TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
                        { Scale = 0.85 }
                    )
                    :Play()
                lastHold = time()
            end
        end)
        UserInputService.InputEnded:Connect(function(input, gameProcessed)
            if input.KeyCode == DAILY_CHEST_KEYCODE and lastHold then
                TweenService
                    :Create(
                        uiScale,
                        TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
                        { Scale = 1 }
                    )
                    :Play()
                if not gameProcessed and not UserInputService:GetFocusedTextBox() and time() - lastHold <= 0.25 then
                    EquipDailyChest()
                end
                lastHold = nil
            end
        end)
    end

    task.spawn(function()
        local remote = ReplicatedStorage.Events:WaitForChild("DailyWinsEvent") :: RemoteEvent
        DailyRemote = remote
        remote.OnClientEvent:Connect(function(status: string)
            if status == "Unequipped" then
                return
            elseif status == "Equipped" then
                ShowNotification("Info", "Click to open!")
            elseif status == "Claimed" then
                ShowNotification("Success", "Chest claimed!")
            elseif status == "NotEnoughWins" then
                local wins = LocalPlayer:GetAttribute("DailyWins")
                local remaining =
                    math.max(0, DailyChestConfig.WinsRequired - (if type(wins) == "number" then wins else 0))
                ShowNotification(
                    "Info",
                    `Win {remaining} more match{if remaining == 1 then "" else "es"}!`
                )
            else
                ShowNotification(
                    "Warning",
                    DAILY_MESSAGES[status] or "Something happened..."
                )
            end
        end)
    end)
end

return DailyChest
