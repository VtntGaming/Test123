--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Modules
local SharedModules = ReplicatedStorage.SharedModules
local Utils = ReplicatedStorage.Utils
local Events = ReplicatedStorage.Events
local RanksPageFunction = Events.RanksPageFunction

local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local LeagueConfig = require(SharedModules.LeagueConfig)
local LeagueUtil = require(Utils.LeagueUtil)
local NotificationUtil = require(Utils.NotificationUtil)
local UIInteractionController = require(script.Parent.UIInteractionController)
local LeagueInfo = require(script.LeagueInfo)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local HUD = MainGui:WaitForChild("HUD")
local RankToggleButton = HUD.LeftButtons.ButtonList.RanksButton
local RanksFrame = MainGui.RanksFrame
local ScrollFrame = RanksFrame.Listing.ScrollingFrame
local TemplateAll = ScrollFrame.TemplateAll
local Loading = RanksFrame.Loading
local Floating = RanksFrame.PlayerRankFrame
local YourRank = RanksFrame.YourRank
local ExitButton = RanksFrame.ExitButton
local Sider = RanksFrame.Sider
local JumpTop = Sider.JumpTop
local JumpSelf = Sider.JumpSelf
local JumpBottom = Sider.JumpBottom
local RankUISound = SoundService.SFX.RankingUIOpen

--// Constants
local LEADERBOARD_CONFIG = LeagueConfig.Leaderboard

local CHUNK = LEADERBOARD_CONFIG.ChunkSize or 50  -- Rows per page request (server caps a span at 100).
local POOL_BUFFER = 4                 -- Extra recycled rows above/below the viewport.
local FETCH_DEBOUNCE = 0.12           -- Scroll must settle this long before a window fetch.
local FETCH_RETRY_DELAY = 1.5         -- A failed / rate-limited chunk is retried after this.
local OPEN_SETTLE_TIMEOUT = 1         -- Max wait for the open pop-in tween before measuring.

local SCROLL_TO_SELF_ON_OPEN = true   -- Centre your row when the frame opens (if you're in the list).
local SHOW_TROPHY_NOTIFICATIONS = true
local VALUE_SUFFIX = ""               -- e.g. "pts" to match the mockup ("98pts")
local OPEN_BUTTON_TAG = "OpenRanksButton" -- Tag any GuiButton with this to make it toggle the frame.

local THUMB_FORMAT = "rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"
local SCROLL_TWEEN_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local BAR_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local GAME_PLAYED_ATTRIBUTE = "GamesPlayed"
local MINIMUM_GAME_PLAYED_REQUIREMENT = LeagueConfig.GamesPlayedRequirement

--// Properties
local IsOpen = false
local IsSetup = false
local IsStarted = false
-- "Your Rank" parts
local Panel = {
	LeagueIcon = YourRank.LeagueIcon,
	LeagueName = YourRank.LeagueName,
	Trophies = YourRank.Trophies,
	GlobalRank = YourRank.GlobalRank,
	ProgressText = nil,
	ProgressBar = YourRank.ProgressBar,
	Fill = YourRank.ProgressBar.Fill,
	NextRank = YourRank.ProgressBar.LeagueIcon,
	InfoButton = YourRank.InfoButton,
	Unranked = YourRank.Unranked,
}        

-- All list geometry is in UNSCALED canvas units (the units of Size/Position offsets,
-- CanvasSize and CanvasPosition). Absolute* reads are divided by the effective UIScale.
local List = {
	Initialized = false,
	Initializing = false,

	RowHeight = 1, Stride = 1, Gap = 0,
	HeaderHeight = 0, PaddingTop = 0, PaddingBottom = 0, ViewHeight = 0,
	AlignX = UDim.new(0, 0), AnchorX = 0,
	TopRows = {}, Pool = {},

	Version = 0, Total = 0,
	CachedUserIds = {}, CachedValues = {}, CachedNames = {},
	FetchedChunks = {},
	PendingChunks = {},
	FetchToken = 0, WantedFrom = 1, WantedTo = 0,

	LastFirst = -1, Dirty = true,
	ScrollTween = nil,
}

-- Local player's live state (attributes written by RanksService).
local Me = { Trophies = 0, LiveRank = 0, SnapshotRank = 0, Overflow = false, GamesPlayed = 0 }
local LastTrophies: number? = nil
local MeRefreshQueued = false
local BoundOpenButtons: { [Instance]: boolean } = {}

--// Types
export type RanksController = {
	Init: () -> (),
	Setup: (self: RanksController) -> (),
	Start: (self: RanksController) -> (),
	Open: () -> (),
	Close: () -> (),
	Toggle: () -> (),
	ScrollToRank: (rank: number, instant: boolean?) -> (),
	ScrollToSelf: () -> (),
}

type RankPageResponse = {
	from: number?,
	version: number?,
	total: number?,
	u: { number }?,
	v: { number }?,
	n: { string }?,
}

type RowItem = typeof(TemplateAll) | typeof(Floating)
type RowParts = {
	Frame: RowItem,
	Rank: typeof(TemplateAll.Rank),
	Title: typeof(TemplateAll.Title),
	Value: typeof(TemplateAll.Value),
	Avatar: typeof(TemplateAll.Avatar),
	LeagueIcon: typeof(TemplateAll.LeagueIcon),
	Stroke: UIStroke,
}

--// Controller
local RanksController = {} :: RanksController

local function FindRowParts(frame: RowItem): RowParts
	return {
		Frame = frame,
		Rank = frame.Rank,
		Title = frame.Title,
		Value = frame.Value,
		Avatar = frame.Avatar,
		LeagueIcon = frame.LeagueIcon,
		Stroke = frame.UIStroke,
	}
end

local function ThumbUrl(userId: number): string
	return string.format(THUMB_FORMAT, userId)
end

local function FormatValue(value: number): string
	return LeagueUtil.FormatNumber(value or 0) .. VALUE_SUFFIX
end

local function RankText(rank: number, overflow: boolean?, compact: boolean?): string
	if overflow then return LeagueUtil.FormatNumber(rank) .. "+" end
	if rank and rank > 0 then return "#" .. LeagueUtil.FormatNumber(rank) end
	return if compact then "-" else "Unranked"
end

-- Product of every UIScale between `gui` and its ScreenGui (both included).
local function GetEffectiveScale(gui: Instance): number
	local scale: number = 1
	local inst: Instance? = gui
	while inst do
		local uiScale = inst:FindFirstChildOfClass("UIScale")
		if uiScale then scale *= uiScale.Scale end
		if inst:IsA("LayerCollector") then break end
		inst = inst.Parent
	end
	return scale
end

-- Unscaled height. Offset heights are exact; Scale heights fall back to AbsoluteSize / scale.
local function MeasureHeight(gui: GuiObject): number?
	if gui.Size.Y.Scale == 0 then return gui.Size.Y.Offset end
	local scale = GetEffectiveScale(gui)
	if scale < 0.05 then return nil end
	return gui.AbsoluteSize.Y / scale
end

local function ConnectButton(inst: Instance, callback: (InputObject, number) -> ())
	if inst:IsA("GuiButton") then
		inst.Activated:Connect(callback)
		return
	end
	
	for _, descendant in ipairs(inst:GetDescendants()) do
		if descendant:IsA("GuiButton") then
			descendant.Activated:Connect(callback)
			return
		end
	end
end

local function SetRowContent(
	rec: RowParts,
	rankLabel: string,
	userId: number?,
	name: string?,
	value: number?,
	isLocal: boolean
)
	if rec.Rank then rec.Rank.Text = rankLabel end
	if userId then
		if rec.Title then rec.Title.Text = if name and name ~= "" then name else "Player" end
		if rec.Value then rec.Value.Text = FormatValue(value or 0) end
		if rec.Avatar then rec.Avatar.Image = ThumbUrl(userId) end
		if rec.LeagueIcon then rec.LeagueIcon.Image = LeagueUtil.GetLeague(value or 0).Icon end
	else
		-- Row not fetched yet.
		if rec.Title then rec.Title.Text = "..." end
		if rec.Value then rec.Value.Text = "" end
		if rec.Avatar then rec.Avatar.Image = "" end
		if rec.LeagueIcon then rec.LeagueIcon.Image = "" end
	end
	if rec.Stroke then rec.Stroke.Enabled = isLocal end
end

-- ==========================================
-- LIST GEOMETRY
-- ==========================================

-- Canvas Y (unscaled, padding included) of the top of a rank's row.
local function SlotTop(rank: number): number
	return List.PaddingTop + List.HeaderHeight + (rank - 1) * List.Stride
end

local function PlaceRow(rec: RowParts, rank: number)
	local y = List.HeaderHeight + (rank - 1) * List.Stride
	rec.Frame.Position = UDim2.new(List.AlignX.Scale, List.AlignX.Offset, 0, y)
end

local function UpdateCanvas()
	local height = List.HeaderHeight + math.max(0, List.Total * List.Stride - List.Gap)
	ScrollFrame.CanvasSize = UDim2.fromOffset(0, List.PaddingTop + height + List.PaddingBottom)
end

local function MaxScroll(): number
	return math.max(0, ScrollFrame.CanvasSize.Y.Offset - List.ViewHeight)
end

local function MeasureViewport(): boolean
	local scale = GetEffectiveScale(ScrollFrame)
	if scale < 0.05 then return false end
	local viewH = ScrollFrame.AbsoluteWindowSize.Y / scale
	if viewH <= 0 then return false end
	local changed = math.abs(viewH - List.ViewHeight) > 1
	List.ViewHeight = viewH
	return changed
end

local function NewRow(template: RowItem, name: string): RowParts
	local frame = template:Clone()
	frame.Name = name
	frame.Visible = false
	frame.AnchorPoint = Vector2.new(List.AnchorX, 0)
	frame.Parent = ScrollFrame
	return FindRowParts(frame)
end

local function EnsurePoolSize()
	local needed = math.ceil(List.ViewHeight / List.Stride) + POOL_BUFFER * 2 + 1
	for i = #List.Pool + 1, needed do
		List.Pool[i] = NewRow(TemplateAll, "Row")
	end
end

-- ==========================================
-- ROW RESOLUTION
-- ==========================================

-- Which snapshot row is drawn in display slot `rank` (0 = the local player, live value).
-- liveRank = live rank (GlobalRank), snapshotRank = snapshot row (SnapshotRank, 0 = not in the list).
-- The server already ranks the live value against the whole snapshot, so the client
-- only shifts the rows between snapshotRank and liveRank by one slot.
local function SourceRank(
	rank: number,
	total: number,
	liveRank: number,
	snapshotRank: number,
	overflow: boolean?
): number
	if snapshotRank <= 0 then snapshotRank = total + 1 end -- not in the list: inserting pushes the rows below down
	if not overflow and liveRank > 0 and liveRank <= total then
		if rank == liveRank then return 0 end
		if liveRank < snapshotRank and rank > liveRank and rank <= snapshotRank then return rank - 1 end -- climbed: rows shift down
		if liveRank > snapshotRank and rank >= snapshotRank and rank < liveRank then return rank + 1 end -- fell: rows shift up
		return rank
	end
	if snapshotRank <= total and rank >= snapshotRank then return rank + 1 end -- fell out of the list: close the gap
	return rank
end

local function FillRow(rec: RowParts, rank: number)
	local src = SourceRank(rank, List.Total, Me.LiveRank, Me.SnapshotRank, Me.Overflow)
	local rankLabel = "#" .. LeagueUtil.FormatNumber(rank)
	if src == 0 then
		SetRowContent(rec, rankLabel, LocalPlayer.UserId, LocalPlayer.DisplayName, Me.Trophies, true)
	else
		local userId = List.CachedUserIds[src]
		SetRowContent(rec, rankLabel, userId, List.CachedNames[src], List.CachedValues[src], userId == LocalPlayer.UserId)
	end
	PlaceRow(rec, rank)
	rec.Frame.Visible = true
end

local function HideRows()
	for _, rec in ipairs(List.TopRows) do rec.Frame.Visible = false end
	for _, rec in ipairs(List.Pool) do rec.Frame.Visible = false end
end

-- ==========================================
-- FLOATING "YOU" ROW
-- ==========================================
local function UpdateFloatingContent()
	SetRowContent(FindRowParts(Floating), RankText(Me.LiveRank, Me.Overflow, true),
		LocalPlayer.UserId, LocalPlayer.DisplayName, Me.Trophies, true)
end

-- Hidden only while your own row is fully inside the viewport.
local function UpdateFloatingVisibility(scrollY: number)
	local liveRank = Me.LiveRank
	local onScreen = false
	if List.Initialized and not Me.Overflow and liveRank > 0 and liveRank <= List.Total then
		local top = SlotTop(liveRank)
		onScreen = top >= scrollY and top + List.RowHeight <= scrollY + List.ViewHeight
	end
	Floating.Visible = not onScreen
end

-- ==========================================
-- DATA FETCHING (version-aware, debounced, deduped)
-- ==========================================
local function AdoptVersion(version: number, total: number)
	List.Version = version
	List.Total = math.max(0, total or 0)
	table.clear(List.CachedUserIds)
	table.clear(List.CachedValues)
	table.clear(List.CachedNames)
	table.clear(List.FetchedChunks)
	List.Dirty = true
	if List.Initialized then UpdateCanvas() end
end

local function StorePage(res: RankPageResponse)
	local from = res.from or 1
	local u, v, n = res.u or {}, res.v or {}, res.n or {}
	for i = 1, #u do
		local r = from + i - 1
		List.CachedUserIds[r], List.CachedValues[r], List.CachedNames[r] = u[i], v[i], n[i]
	end
end

local FillVisible: (force: boolean?) -> ()

local function FetchChunk(chunk: number)
	if List.FetchedChunks[chunk] or List.PendingChunks[chunk] == List.Version then return end
	local version = List.Version
	List.PendingChunks[chunk] = version
	local startRank = chunk * CHUNK + 1

	task.spawn(function()
		local ok, result = pcall(function()
			return RanksPageFunction:InvokeServer(startRank, startRank + CHUNK - 1)
		end)
		if List.PendingChunks[chunk] == version then List.PendingChunks[chunk] = nil end

		if not ok or type(result) ~= "table" then
			-- Failed or rate-limited (server returns nil): retry instead of caching an empty chunk.
			task.delay(FETCH_RETRY_DELAY, function()
				List.Dirty = true
				FillVisible()
			end)
			return
		end

		local res = result :: RankPageResponse
		local resVersion = res.version or 0
		if resVersion ~= List.Version then
			if resVersion < List.Version then
				-- Stale answer from before a snapshot change: ask again.
				List.Dirty = true
				FillVisible()
				return
			end
			AdoptVersion(resVersion, res.total or 0) -- the page beat the RanksVersion attribute
		end

		StorePage(res)
		List.FetchedChunks[chunk] = true
		List.Dirty = true
		FillVisible()
	end)
end

local function EnsureRange(fromRank: number, toRank: number)
	fromRank = math.max(1, fromRank)
	toRank = math.min(toRank, List.Total + 1) -- +1: the row that closes the gap when you fall out
	if toRank < fromRank then return end
	for chunk = (fromRank - 1) // CHUNK, (toRank - 1) // CHUNK do
		FetchChunk(chunk)
	end
end

-- Debounced so a fling doesn't fire a request per frame.
local function RequestWindow(fromRank: number, toRank: number)
	List.WantedFrom, List.WantedTo = fromRank, toRank
	List.FetchToken += 1
	local token = List.FetchToken
	task.delay(FETCH_DEBOUNCE, function()
		if List.FetchToken == token and RanksFrame.Visible then -- skip if the frame closed meanwhile
			EnsureRange(List.WantedFrom, List.WantedTo)
		end
	end)
end

-- ==========================================
-- RENDER
-- ==========================================
FillVisible = function(force: boolean?)
	if not List.Initialized then return end
	if not RanksFrame.Visible then
		List.Dirty = true
		return
	end

	local total = List.Total
	if Loading then Loading.Visible = total <= 0 end
	local scrollY = ScrollFrame.CanvasPosition.Y

	if total <= 0 then
		HideRows()
		UpdateFloatingVisibility(scrollY)
		return
	end

	local poolSize = #List.Pool
	local firstVisible = math.floor((scrollY - List.PaddingTop - List.HeaderHeight) / List.Stride) + 1
	local windowFirst = math.clamp(firstVisible - POOL_BUFFER, 4, math.max(4, total - poolSize + 1))

	-- Scrolling inside the same window: nothing to redraw.
	if not force and not List.Dirty and windowFirst == List.LastFirst then
		UpdateFloatingVisibility(scrollY)
		return
	end
	List.LastFirst, List.Dirty = windowFirst, false

	-- Ranks 1-3 use their own templates and are always drawn.
	for i, rec in ipairs(List.TopRows) do
		if i <= total then FillRow(rec, i) else rec.Frame.Visible = false end
	end

	-- Recycled pool for ranks >= 4.
	local windowLast = math.min(total, windowFirst + poolSize - 1)
	for i, rec in ipairs(List.Pool) do
		local rank = windowFirst + i - 1
		if rank <= windowLast then FillRow(rec, rank) else rec.Frame.Visible = false end
	end

	EnsureRange(1, math.min(total, 3) + 1) -- top rows (+1 for a shifted neighbour), never debounced
	if windowLast >= windowFirst then
		RequestWindow(windowFirst - 1, windowLast + 1) -- ±1 for shifted neighbours
	end
	UpdateFloatingVisibility(scrollY)
end

-- ==========================================
-- SCROLLING
-- ==========================================
local function CancelScrollTween()
	if List.ScrollTween then
		List.ScrollTween:Cancel()
		List.ScrollTween = nil
	end
end

local function ScrollToRank(rank: number, instant: boolean?)
	if not List.Initialized or List.Total <= 0 then return end
	rank = math.clamp(rank, 1, List.Total)
	local target = math.clamp(SlotTop(rank) - (List.ViewHeight - List.RowHeight) / 2, 0, MaxScroll()) -- centre the row

	CancelScrollTween()
	if instant then
		ScrollFrame.CanvasPosition = Vector2.new(0, target)
		return
	end
	local tween = TweenService:Create(ScrollFrame, SCROLL_TWEEN_INFO, { CanvasPosition = Vector2.new(0, target) })
	List.ScrollTween = tween
	tween.Completed:Once(function()
		if List.ScrollTween == tween then List.ScrollTween = nil end
	end)
	tween:Play()
end

-- Your row if you're in the list, otherwise the bottom of the list (you're below it).
local function ScrollToSelf()
	if not Me.Overflow and Me.LiveRank > 0 and Me.LiveRank <= List.Total then
		ScrollToRank(Me.LiveRank)
	else
		ScrollToRank(List.Total)
	end
end

-- ==========================================
-- "YOUR RANK" PANEL
-- ==========================================
local function UpdateLocalPlayerRank()
	local trophies = Me.Trophies
	local league = LeagueUtil.GetLeague(trophies)
	local progress, _, nextMin = 0, 0, 0

	local icon = "rbxassetid://94065471951439"
	local nextRankIcon = "rbxassetid://94065471951439"
	local leagueName = "UNRANKED"
	local trophiesDisplay = `{Me.GamesPlayed}/{MINIMUM_GAME_PLAYED_REQUIREMENT}🏆`
	local globalRank = ``

	local iconColor = Color3.new(0, 0, 0)

	local isUnranked = Me.GamesPlayed < MINIMUM_GAME_PLAYED_REQUIREMENT

	Panel.ProgressBar.Visible = not isUnranked
	Panel.Unranked.Visible = isUnranked

	if not isUnranked then		
		icon = league.Icon
		leagueName = league.Name
		trophiesDisplay = LeagueUtil.FormatNumber(trophies) .. "🏆"
		globalRank = RankText(Me.LiveRank, Me.Overflow)
		iconColor = Color3.new(1, 1, 1)
		
		local currentIndex = table.find(LeagueConfig.Leagues, league)

		if currentIndex then
			local nextRank = LeagueConfig.Leagues[math.min(currentIndex, #LeagueConfig.Leagues)]			

			nextRankIcon = nextRank.Icon
		end

		progress, _, nextMin = LeagueUtil.GetProgress(trophies)
	end

	Panel.LeagueIcon.Image = icon
	Panel.LeagueIcon.ImageColor3 = iconColor
	Panel.LeagueName.Text = leagueName
	Panel.Trophies.Text = trophiesDisplay
	Panel.GlobalRank.Text = globalRank
	Panel.NextRank.Image = nextRankIcon
	
	if Panel.ProgressText then		
		Panel.ProgressText.Text = if nextMin
				then LeagueUtil.FormatNumber(trophies) .. " / " .. LeagueUtil.FormatNumber(nextMin)
				else "MAX"
	end
	if Panel.Fill then
		local size = Panel.Fill.Size
		TweenService:Create(Panel.Fill, BAR_TWEEN_INFO, {
			Size = UDim2.new(progress, 0, size.Y.Scale, size.Y.Offset),
		}):Play()
	end
end
-- ==========================================
-- LIVE UPDATES
-- ==========================================
local function ReadMe()
	Me.Trophies = tonumber(LocalPlayer:GetAttribute("Trophies")) or 0
	Me.LiveRank = tonumber(LocalPlayer:GetAttribute("GlobalRank")) or 0
	Me.SnapshotRank = tonumber(LocalPlayer:GetAttribute("SnapshotRank")) or 0
	Me.Overflow = LocalPlayer:GetAttribute("GlobalRankOverflow") == true
	Me.GamesPlayed = tonumber(LocalPlayer:GetAttribute(GAME_PLAYED_ATTRIBUTE)) or 0
end

-- Trophies, GlobalRank and SnapshotRank usually change in the same frame: batch them.
local function ScheduleMeRefresh()
	if MeRefreshQueued then return end
	MeRefreshQueued = true
	task.defer(function()
		MeRefreshQueued = false
		ReadMe()
		UpdateLocalPlayerRank()
		UpdateFloatingContent()
		List.Dirty = true
		FillVisible()
	end)
end

local function OnTrophiesChanged()
	local newTrophies = tonumber(LocalPlayer:GetAttribute("Trophies")) or 0
	local oldTrophies = LastTrophies
	LastTrophies = newTrophies
	ScheduleMeRefresh()

	if not SHOW_TROPHY_NOTIFICATIONS or oldTrophies == nil then return end
	if LocalPlayer:GetAttribute("DataLoaded") ~= true then return end -- initial load, not a match result
	local delta = newTrophies - oldTrophies
	if delta == 0 then return end

	local oldIndex = LeagueUtil.GetLeagueIndex(oldTrophies)
	local newIndex = LeagueUtil.GetLeagueIndex(newTrophies)
	local leagueName = LeagueUtil.GetLeague(newTrophies).Name
	if newIndex > oldIndex then
		NotificationUtil.Show("Success", "🏆 Promoted to " .. leagueName .. "!")
	elseif newIndex < oldIndex then
		NotificationUtil.Show("Warning", "Dropped to " .. leagueName .. " league")
	else
		NotificationUtil.Show(if delta > 0 then "Success" else "Warning",
			(if delta > 0 then "+" else "") .. tostring(delta) .. " 🏆")
	end
end

local function OnRanksVersionChanged()
	local version = tonumber(ReplicatedStorage:GetAttribute("RanksVersion")) or 0
	local total = tonumber(ReplicatedStorage:GetAttribute("RanksTotal")) or 0
	if version ~= List.Version then
		AdoptVersion(version, total)
	elseif total ~= List.Total then
		List.Total = total
		List.Dirty = true
		if List.Initialized then UpdateCanvas() end
	end
	FillVisible()
end

-- ==========================================
-- LIST INITIALIZATION
-- ==========================================
local function ConfigureListLayout()
	local sf = ScrollFrame

	List.AlignX = TemplateAll.Position.X
	List.AnchorX = TemplateAll.AnchorPoint.X

	-- Manual layout. AutomaticCanvasSize miscomputes the canvas when an ancestor has a
	-- UIScale (ToggleFrame always adds one), so the canvas is sized here instead and the
	-- UIListLayout is replaced by explicit positions. Its padding/alignment are kept.
	local layout = sf.UIListLayout
	if layout then
		List.Gap = layout.Padding.Offset
		if layout.HorizontalAlignment == Enum.HorizontalAlignment.Center then
			List.AlignX, List.AnchorX = UDim.new(0.5, 0), 0.5
		elseif layout.HorizontalAlignment == Enum.HorizontalAlignment.Right then
			List.AlignX, List.AnchorX = UDim.new(1, 0), 1
		else
			List.AlignX, List.AnchorX = UDim.new(0, 0), 0
		end
		layout:Destroy()
	end
	sf.AutomaticCanvasSize = Enum.AutomaticSize.None

	local padding = sf.UIPadding
	if padding then
		List.PaddingTop, List.PaddingBottom = padding.PaddingTop.Offset, padding.PaddingBottom.Offset
	end

	TemplateAll.Visible = false

	List.RowHeight = math.max(1, MeasureHeight(TemplateAll) or 1)
	List.Stride = List.RowHeight + List.Gap
end

local function CreateListRows()
	List.TopRows = {
		NewRow(TemplateAll, "TopRow1"),
		NewRow(TemplateAll, "TopRow2"),
		NewRow(TemplateAll, "TopRow3"),
	}
end

local function BindListEvents()
	local sf = ScrollFrame
	sf:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		FillVisible()
	end)

	local currentCam = workspace.CurrentCamera
	if currentCam then
		currentCam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if MeasureViewport() then
				EnsurePoolSize()
				List.Dirty = true
				FillVisible()
			end
		end)
	end

	-- A manual scroll cancels an auto-scroll instead of fighting it.
	local function onScrollInput(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseWheel or t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			CancelScrollTween()
		end
	end
	sf.InputBegan:Connect(onScrollInput)
	sf.InputChanged:Connect(onScrollInput)
end

local function InitList()
	if List.Initialized or List.Initializing then return end
	List.Initializing = true

	ConfigureListLayout()
	CreateListRows()
	MeasureViewport()
	EnsurePoolSize()
	BindListEvents()

	List.Initialized = true
	List.Initializing = false
	UpdateCanvas()
	FillVisible(true)
end

-- Waits for ToggleFrame's pop-in tween so the first measurement isn't taken at scale ~0.
local function WaitForOpenSettled()
	local started = os.clock()
	while os.clock() - started < OPEN_SETTLE_TIMEOUT do
		local uiScale = RanksFrame.UIScale
		if (not uiScale or math.abs(uiScale.Scale - 1) < 0.001) and ScrollFrame.AbsoluteWindowSize.Y > 0 then
			return
		end
		task.wait()
	end
end

local function OnOpened()
	task.spawn(function()
		WaitForOpenSettled()
		if not RanksFrame.Visible then return end

		InitList()
		if MeasureViewport() then EnsurePoolSize() end
		ReadMe()
		UpdateLocalPlayerRank()
		UpdateFloatingContent()
		OnRanksVersionChanged()
		List.Dirty = true
		FillVisible(true)

		if SCROLL_TO_SELF_ON_OPEN and not Me.Overflow and Me.LiveRank > 0 and Me.LiveRank <= List.Total then
			ScrollToRank(Me.LiveRank)
		end
	end)
end

local function BindPlayerAttributeSignals()
	for _, attr in ipairs({ "GlobalRank", "SnapshotRank", "GlobalRankOverflow", GAME_PLAYED_ATTRIBUTE }) do
		LocalPlayer:GetAttributeChangedSignal(attr):Connect(ScheduleMeRefresh)
	end
	LocalPlayer:GetAttributeChangedSignal("Trophies"):Connect(OnTrophiesChanged)
	LocalPlayer:GetAttributeChangedSignal("DataLoaded"):Connect(function()
		LastTrophies = tonumber(LocalPlayer:GetAttribute("Trophies")) or 0 -- baseline: no popup for the load itself
		ScheduleMeRefresh()
	end)
	if LocalPlayer:GetAttribute("DataLoaded") == true then
		LastTrophies = tonumber(LocalPlayer:GetAttribute("Trophies")) or 0
	end
end

local function BindRanksVersionSignals()
	ReplicatedStorage:GetAttributeChangedSignal("RanksVersion"):Connect(OnRanksVersionChanged)
	ReplicatedStorage:GetAttributeChangedSignal("RanksTotal"):Connect(OnRanksVersionChanged)
end

local function BindFrameVisibility()
	RanksFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if RanksFrame.Visible then
			OnOpened()
		else
			CancelScrollTween()
		end
	end)
end

local function BindOpenButton(button: Instance)
	if BoundOpenButtons[button] or not button:IsA("GuiButton") then return end
	if not button:IsDescendantOf(PlayerGui) then return end
	BoundOpenButtons[button] = true
	button.Activated:Connect(function()
		RanksController.Toggle()
	end)
end

local function BindTaggedOpenButtons()
	for _, button in ipairs(CollectionService:GetTagged(OPEN_BUTTON_TAG)) do
		task.spawn(BindOpenButton, button)
	end
	CollectionService:GetInstanceAddedSignal(OPEN_BUTTON_TAG):Connect(BindOpenButton)
end

local function TriggerSider(siderType: string)
	if siderType == "JumpSelf" then
		ScrollToSelf()
	elseif siderType == "JumpTop" then
		ScrollToRank(1)
	elseif siderType == "JumpBottom" then
		ScrollToRank(List.Total)
	end

	for _, obj in ipairs(Sider:GetChildren()) do
		if obj:IsA("ImageButton") then
			obj.Image = obj.Name == siderType and "rbxassetid://72940564227520" or "rbxassetid://85490089980863"
		end
	end
end

local function BindNavigationButtons()
	ConnectButton(Floating, function()
		TriggerSider("JumpSelf")
	end)
	ConnectButton(JumpTop, function()
		TriggerSider("JumpTop")
	end)
	ConnectButton(JumpSelf, function()
		TriggerSider("JumpSelf")
	end)
	ConnectButton(JumpBottom, function()
		TriggerSider("JumpBottom")
	end)
end

local function BindLeagueInfoButtons()
	if Panel.InfoButton and LeagueInfo then
		ConnectButton(Panel.InfoButton, function()
			LeagueInfo:SetVisible(not LeagueInfo.IsVisible)
		end)
	end

	ConnectButton(YourRank.LeagueIcon.Button, function()
		LeagueInfo:SetVisible(not LeagueInfo.IsVisible)
	end)
end

local function BindRankToggleButton()
	ConnectButton(RankToggleButton, function()
		if IsOpen then
			RanksController.Close()
		else
			RanksController.Open()
		end
	end)
end

--// APIs
function RanksController.Open()
	IsOpen = true
	SoundService:PlayLocalSound(RankUISound)
	if not RanksFrame.Visible then
		UIInteractionController.ToggleFrame(RanksFrame, true)

		TweenUtils.PlayTweenSequence({
			TweenService:Create(YourRank, TweenInfo.new(0), {
				Position = UDim2.fromScale(0.225, 0.25)
			}),
			TweenService:Create(RanksFrame.Header, TweenInfo.new(0), {
				Position = UDim2.fromScale(-0.25, -0.107)
			}),
			true,
			TweenService:Create(YourRank, TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
				Position = UDim2.fromScale(0.225, 0.45)
			}),			
			TweenService:Create(RanksFrame.Header, TweenInfo.new(1, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
				Position = UDim2.fromScale(-0.049, -0.107)
			}),
		})
	end
end

function RanksController.Close()
	if LeagueInfo.IsVisible then
		LeagueInfo:SetVisible(false)
	end
	IsOpen = false
	if RanksFrame.Visible then
		UIInteractionController.ToggleFrame(RanksFrame, false)
	end
end

function RanksController.Toggle()
	if RanksFrame.Visible then RanksController.Close() else RanksController.Open() end
end

RanksController.ScrollToRank = ScrollToRank
RanksController.ScrollToSelf = ScrollToSelf

function RanksController:Setup()
	if IsSetup then return end
	IsSetup = true

	LeagueInfo:Setup()
	ReadMe()
end

function RanksController:Start()
	if IsStarted then return end
	if not IsSetup then self:Setup() end
	IsStarted = true

	BindPlayerAttributeSignals()
	BindRanksVersionSignals()
	BindFrameVisibility()

	ConnectButton(ExitButton, RanksController.Close)
	BindTaggedOpenButtons()

	BindNavigationButtons()
	BindLeagueInfoButtons()
	BindRankToggleButton()

	UpdateLocalPlayerRank()
	UpdateFloatingContent()
	OnRanksVersionChanged()
	TriggerSider("JumpTop")
	if RanksFrame.Visible then OnOpened() end
	RanksController.Close()
	LeagueInfo:Start()
end

function RanksController.Init()
	RanksController:Setup()
	RanksController:Start()
end

return RanksController
