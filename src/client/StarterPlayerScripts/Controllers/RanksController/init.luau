--!strict
-- Presents ranks controller behavior using logical Player data access.
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Module references
local SharedModules = ReplicatedStorage.SharedModules
local Utils = ReplicatedStorage.Utils
local Events = ReplicatedStorage.Events
local RanksPageFunction = Events.RanksPageFunction

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
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
-- TODO: Where there's a proper template, use the new reference instead
local TemplateFirst = TemplateAll
local TemplateSecond = TemplateAll
local TemplateThird = TemplateAll
local Loading = RanksFrame.Loading
local Floating = RanksFrame.PlayerRankFrame
local YourRank = RanksFrame.YourRank
local ExitButton = RanksFrame.ExitButton
local Sider = RanksFrame.Sider
local JumpTop = Sider.JumpTop
local JumpSelf = Sider.JumpSelf
local JumpBottom = Sider.JumpBottom
local RankUISound = SoundService.SFX.RankingUIOpen

-- Temp
-- local NAMES = {
-- 	Frame = "RanksFrame",                  -- direct child of MainGui

-- 	-- "Your Rank" panel
-- 	YourRank = "YourRank",
-- 	PanelLeagueIcon = "LeagueIcon",
-- 	PanelLeagueName = "LeagueName",     -- optional
-- 	PanelTrophies = "Trophies",
-- 	PanelGlobalRank = "GlobalRank",
-- 	ProgressBar = "ProgressBar",
-- 	ProgressFill = "Fill",              -- child of ProgressBar, Size.X.Scale = progress
-- 	ProgressText = "ProgressText",      -- optional, "48 / 500"
-- 	InfoButton = "InfoButton",          -- optional, toggles LeagueInfo
-- 	LeagueInfo = "LeagueInfo",          -- optional popup; needs a "Template" row (LeagueIcon, LeagueName, MinTrophies)

-- 	-- "World Rank" list
-- 	ScrollingFrame = "ScrollingFrame",  -- required
-- 	Header = "Top",                     -- optional header kept at the top of the canvas
-- 	Loading = "Loading",                -- optional, shown while no snapshot exists
-- 	TemplateFirst = "TemplateFirst",    -- optional (falls back to TemplateAll)
-- 	TemplateSecond = "TemplateSecond",  -- optional
-- 	TemplateThird = "TemplateThird",    -- optional
-- 	TemplateAll = "TemplateAll",        -- required
-- 	PlayerRankFrame = "PlayerRankFrame",-- optional floating "you" row
-- 	ExitButton = "ExitButton",          -- optional
-- 	Sider = "Sider",                    -- optional container of jump buttons:
-- 	JumpTop = "JumpTop",                --   scroll to #1
-- 	JumpSelf = "JumpSelf",              --   scroll to your row (or the bottom if you're below the list)
-- 	JumpBottom = "JumpBottom",          --   scroll to the last row

-- 	-- Row children (searched recursively in every row and in PlayerRankFrame)
-- 	RowRank = "Rank",
-- 	RowTitle = "Title",                 -- optional (the mockup shows no name)
-- 	RowValue = "Value",
-- 	RowAvatar = "Avatar",
-- 	RowLeagueIcon = "LeagueIcon",
-- 	RowStroke = "LocalPlayerStroke",    -- optional UIStroke highlighting your own row
-- }
-- Temp

--// Constants
local Config = LeagueConfig.Leaderboard

-- Instance names: change these to match your RanksFrame hierarchy.
-- Optional parts may be missing; everything is searched recursively under RanksFrame.

local CHUNK = Config.ChunkSize or 50  -- Rows per page request (server caps a span at 100).
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
local MINUMUM_RANKED_MATCH = 10

--// Local Properties
local RanksController = {}
local FloatingRec = nil
local IsOpen = false
-- "Your Rank" parts
local Panel = {
	LeagueIcon = YourRank.LeagueIcon,
	LeagueName = YourRank.LeagueName,
	Trophies = YourRank.Trophies,
	GlobalRank = YourRank.GlobalRank,
	ProgressText = nil, -- ProgressText
	ProgressBar = YourRank.ProgressBar,
	Fill = YourRank.ProgressBar.Fill,
	NextRank = YourRank.ProgressBar.LeagueIcon,
	InfoButton = YourRank.InfoButton,
	Unranked = YourRank.Unranked,
}        

-- All list geometry is in UNSCALED canvas units (the units of Size/Position offsets,
-- CanvasSize and CanvasPosition). Absolute* reads are divided by the effective UIScale.
local List = {
	initialized = false,
	initializing = false,

	rowH = 1, stride = 1, gap = 0,
	headerH = 0, padTop = 0, padBottom = 0, viewH = 0,
	alignX = UDim.new(0, 0), anchorX = 0,
	topRows = {}, pool = {},

	version = 0, total = 0,          -- snapshot version this cache belongs to, rows in the list
	cacheU = {}, cacheV = {}, cacheN = {},
	fetched = {},                    -- [chunk] = true
	pending = {},                    -- [chunk] = version being requested
	fetchToken = 0, wantFrom = 1, wantTo = 0,

	lastFirst = -1, dirty = true,
	scrollTween = nil,
}

-- Local player's live state (attributes written by RanksService).
local Me = { trophies = 0, liveRank = 0, snapRank = 0, overflow = false, gamePlayed = 0 }
local LastTrophies = nil
local MeRefreshQueued = false
local BoundOpenButtons = {}

--// Types
type RowItem = typeof(TemplateAll)
type RowParts = {	
	Frame: RowItem,
	Rank: typeof(TemplateAll.Rank),
	Title: typeof(TemplateAll.Title),
	Value: typeof(TemplateAll.Value),
	Avatar: typeof(TemplateAll.Avatar),
	LeagueIcon: typeof(TemplateAll.LeagueIcon),
	Stroke: UIStroke,
}

--// Local functions
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

local function ResolveReferences()
	FloatingRec = if Floating then FindRowParts(Floating :: any) else nil
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
	if not inst then return end
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

local function SetRowContent(rec: RowParts, rankLabel, userId, name, value, isLocal)
	if rec.Rank then rec.Rank.Text = rankLabel end
	if userId then
		if rec.Title then rec.Title.Text = if name and name ~= "" then name else "Player" end
		if rec.Value then rec.Value.Text = FormatValue(value) end
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
	return List.padTop + List.headerH + (rank - 1) * List.stride
end

local function PlaceRow(rec: RowParts, rank: number)
	-- Position is relative to the padded area, so no padTop here.
	rec.Frame.Position = UDim2.new(List.alignX.Scale, List.alignX.Offset, 0, List.headerH + (rank - 1) * List.stride)
end

local function UpdateCanvas()
	local height = List.headerH + math.max(0, List.total * List.stride - List.gap)
	ScrollFrame.CanvasSize = UDim2.fromOffset(0, List.padTop + height + List.padBottom)
end

local function MaxScroll()
	return math.max(0, ScrollFrame.CanvasSize.Y.Offset - List.viewH)
end

local function MeasureViewport()
	local scale = GetEffectiveScale(ScrollFrame)
	if scale < 0.05 then return false end
	local viewH = ScrollFrame.AbsoluteWindowSize.Y / scale
	if viewH <= 0 then return false end
	local changed = math.abs(viewH - List.viewH) > 1
	List.viewH = viewH
	return changed
end

local function NewRow(template: RowItem, name)
	local frame = template:Clone()
	frame.Name = name
	frame.Visible = false
	frame.AnchorPoint = Vector2.new(List.anchorX, 0)
	frame.Parent = ScrollFrame
	return FindRowParts(frame)
end

local function EnsurePoolSize()
	local needed = math.ceil(List.viewH / List.stride) + POOL_BUFFER * 2 + 1
	for i = #List.pool + 1, needed do
		List.pool[i] = NewRow(TemplateAll, "Row")
	end
end

-- ==========================================
-- ROW RESOLUTION
-- ==========================================

-- Which snapshot row is drawn in display slot `rank` (0 = the local player, live value).
-- liveRank = live rank (GlobalRank), snapshotRank = snapshot row (SnapshotRank, 0 = not in the list).
-- The server already ranks the live value against the whole snapshot, so the client
-- only shifts the rows between snapshotRank and liveRank by one slot.
local function SourceRank(rank: number, total: number, liveRank: number, snapshotRank: number, overflow: boolean?)
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

local function FillRow(rec, rank)
	local src = SourceRank(rank, List.total, Me.liveRank, Me.snapRank, Me.overflow)
	local rankLabel = "#" .. LeagueUtil.FormatNumber(rank)
	if src == 0 then
		SetRowContent(rec, rankLabel, LocalPlayer.UserId, LocalPlayer.DisplayName, Me.trophies, true)
	else
		local userId = List.cacheU[src]
		SetRowContent(rec, rankLabel, userId, List.cacheN[src], List.cacheV[src], userId == LocalPlayer.UserId)
	end
	PlaceRow(rec, rank)
	rec.Frame.Visible = true
end

local function HideRows()
	for _, rec in ipairs(List.topRows) do rec.Frame.Visible = false end
	for _, rec in ipairs(List.pool) do rec.Frame.Visible = false end
end

-- ==========================================
-- FLOATING "YOU" ROW
-- ==========================================
local function UpdateFloatingContent()
	if not FloatingRec then return end
	SetRowContent(FloatingRec, RankText(Me.liveRank, Me.overflow, true),
		LocalPlayer.UserId, LocalPlayer.DisplayName, Me.trophies, true)
end

-- Hidden only while your own row is fully inside the viewport.
local function UpdateFloatingVisibility(scrollY)
	if not Floating then return end
	local liveRank = Me.liveRank
	local onScreen = false
	if List.initialized and not Me.overflow and liveRank > 0 and liveRank <= List.total then
		local top = SlotTop(liveRank)
		onScreen = top >= scrollY and top + List.rowH <= scrollY + List.viewH
	end
	Floating.Visible = not onScreen
end

-- ==========================================
-- DATA FETCHING (version-aware, debounced, deduped)
-- ==========================================
local function AdoptVersion(version, total)
	List.version = version
	List.total = math.max(0, total or 0)
	table.clear(List.cacheU)
	table.clear(List.cacheV)
	table.clear(List.cacheN)
	table.clear(List.fetched)
	List.dirty = true
	if List.initialized then UpdateCanvas() end
end

local function StorePage(res)
	local from = tonumber(res.from) or 1
	local u, v, n = res.u or {}, res.v or {}, res.n or {}
	for i = 1, #u do
		local r = from + i - 1
		List.cacheU[r], List.cacheV[r], List.cacheN[r] = u[i], v[i], n[i]
	end
end

local FillVisible: (force: boolean?) -> ()

local function FetchChunk(chunk: number)
	if List.fetched[chunk] or List.pending[chunk] == List.version then return end
	local version = List.version
	List.pending[chunk] = version
	local startRank = chunk * CHUNK + 1

	task.spawn(function()
		local ok, res = pcall(function()
			return RanksPageFunction:InvokeServer(startRank, startRank + CHUNK - 1)
		end)
		if List.pending[chunk] == version then List.pending[chunk] = nil end

		if not ok or type(res) ~= "table" then
			-- Failed or rate-limited (server returns nil): retry instead of caching an empty chunk.
			task.delay(FETCH_RETRY_DELAY, function()
				List.dirty = true
				FillVisible()
			end)
			return
		end

		local resVersion = tonumber(res.version) or 0
		if resVersion ~= List.version then
			if resVersion < List.version then
				-- Stale answer from before a snapshot change: ask again.
				List.dirty = true
				FillVisible()
				return
			end
			AdoptVersion(resVersion, res.total) -- the page beat the RanksVersion attribute
		end

		StorePage(res)
		List.fetched[chunk] = true
		List.dirty = true
		FillVisible()
	end)
end

local function EnsureRange(fromRank: number, toRank: number)
	fromRank = math.max(1, fromRank)
	toRank = math.min(toRank, List.total + 1) -- +1: the row that closes the gap when you fall out
	if toRank < fromRank then return end
	for chunk = (fromRank - 1) // CHUNK, (toRank - 1) // CHUNK do
		FetchChunk(chunk)
	end
end

-- Debounced so a fling doesn't fire a request per frame.
local function RequestWindow(fromRank, toRank)
	List.wantFrom, List.wantTo = fromRank, toRank
	List.fetchToken += 1
	local token = List.fetchToken
	task.delay(FETCH_DEBOUNCE, function()
		if List.fetchToken == token and RanksFrame.Visible then -- skip if the frame closed meanwhile
			EnsureRange(List.wantFrom, List.wantTo)
		end
	end)
end

-- ==========================================
-- RENDER
-- ==========================================
FillVisible = function(force: boolean?)
	if not List.initialized then return end
	if not RanksFrame.Visible then
		List.dirty = true
		return
	end

	local total = List.total
	if Loading then Loading.Visible = total <= 0 end
	local scrollY = ScrollFrame.CanvasPosition.Y

	if total <= 0 then
		HideRows()
		UpdateFloatingVisibility(scrollY)
		return
	end

	local poolSize = #List.pool
	local firstVisible = math.floor((scrollY - List.padTop - List.headerH) / List.stride) + 1
	local windowFirst = math.clamp(firstVisible - POOL_BUFFER, 4, math.max(4, total - poolSize + 1))

	-- Scrolling inside the same window: nothing to redraw.
	if not force and not List.dirty and windowFirst == List.lastFirst then
		UpdateFloatingVisibility(scrollY)
		return
	end
	List.lastFirst, List.dirty = windowFirst, false

	-- Ranks 1-3 use their own templates and are always drawn.
	for i, rec in ipairs(List.topRows) do
		if i <= total then FillRow(rec, i) else rec.Frame.Visible = false end
	end

	-- Recycled pool for ranks >= 4.
	local windowLast = math.min(total, windowFirst + poolSize - 1)
	for i, rec in ipairs(List.pool) do
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
	if List.scrollTween then
		List.scrollTween:Cancel()
		List.scrollTween = nil
	end
end

local function ScrollToRank(rank: number, instant: boolean?)
	if not List.initialized or List.total <= 0 then return end
	rank = math.clamp(rank, 1, List.total)
	local target = math.clamp(SlotTop(rank) - (List.viewH - List.rowH) / 2, 0, MaxScroll()) -- centre the row

	CancelScrollTween()
	if instant then
		ScrollFrame.CanvasPosition = Vector2.new(0, target)
		return
	end
	local tween = TweenService:Create(ScrollFrame, SCROLL_TWEEN_INFO, { CanvasPosition = Vector2.new(0, target) })
	List.scrollTween = tween
	tween.Completed:Once(function()
		if List.scrollTween == tween then List.scrollTween = nil end
	end)
	tween:Play()
end

-- Your row if you're in the list, otherwise the bottom of the list (you're below it).
local function ScrollToSelf()
	if not Me.overflow and Me.liveRank > 0 and Me.liveRank <= List.total then
		ScrollToRank(Me.liveRank)
	else
		ScrollToRank(List.total)
	end
end

-- ==========================================
-- "YOUR RANK" PANEL
-- ==========================================
local function UpdateLocalPlayerRank()
	local trophies = Me.trophies
	local league = LeagueUtil.GetLeague(trophies)
	local progress, _, nextMin = 0, 0, 0

	local icon = "rbxassetid://94065471951439"
	local nextRankIcon = "rbxassetid://94065471951439"
	local leagueName = "UNRANKED"
	local trophiesDisplay = `{Me.gamePlayed}/{MINUMUM_RANKED_MATCH}🏆`
	local globalRank = ``

	local iconColor = Color3.new(0, 0, 0)

	local isUnranked = Me.gamePlayed < MINUMUM_RANKED_MATCH

	Panel.ProgressBar.Visible = not isUnranked
	Panel.Unranked.Visible = isUnranked

	if not isUnranked then		
		icon = league.Icon
		leagueName = league.Name
		trophiesDisplay = LeagueUtil.FormatNumber(trophies) .. "🏆"
		globalRank = RankText(Me.liveRank, Me.overflow)
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
	Me.trophies = tonumber(PlayerData.Get(LocalPlayer, "Trophies")) or 0
	Me.liveRank = tonumber(PlayerData.Get(LocalPlayer, "GlobalRank")) or 0
	Me.snapRank = tonumber(PlayerData.Get(LocalPlayer, "SnapshotRank")) or 0
	Me.overflow = PlayerData.Get(LocalPlayer, "GlobalRankOverflow") == true
	Me.gamePlayed = tonumber(PlayerData.Get(LocalPlayer, GAME_PLAYED_ATTRIBUTE)) or 0
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
		List.dirty = true
		FillVisible()
	end)
end

local function OnTrophiesChanged()
	local newTrophies = tonumber(PlayerData.Get(LocalPlayer, "Trophies")) or 0
	local oldTrophies = LastTrophies
	LastTrophies = newTrophies
	ScheduleMeRefresh()

	if not SHOW_TROPHY_NOTIFICATIONS or oldTrophies == nil then return end
	if PlayerData.Get(LocalPlayer, "DataLoaded") ~= true then
		return
	end -- initial load, not a match result
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
	local version = ReplicatedValues.GetNumber(ReplicatedStorage, "RanksVersion") or 0
	local total = ReplicatedValues.GetNumber(ReplicatedStorage, "RanksTotal") or 0
	if version ~= List.version then
		AdoptVersion(version, total)
	elseif total ~= List.total then
		List.total = total
		List.dirty = true
		if List.initialized then UpdateCanvas() end
	end
	FillVisible()
end

-- ==========================================
-- SETUP
-- ==========================================
local function InitList()
	if List.initialized or List.initializing then return end
	List.initializing = true
	local sf = ScrollFrame

	List.alignX = TemplateAll.Position.X
	List.anchorX = TemplateAll.AnchorPoint.X

	-- Manual layout. AutomaticCanvasSize miscomputes the canvas when an ancestor has a
	-- UIScale (ToggleFrame always adds one), so the canvas is sized here instead and the
	-- UIListLayout is replaced by explicit positions. Its padding/alignment are kept.
	local layout = sf.UIListLayout
	if layout then
		List.gap = layout.Padding.Offset
		if layout.HorizontalAlignment == Enum.HorizontalAlignment.Center then
			List.alignX, List.anchorX = UDim.new(0.5, 0), 0.5
		elseif layout.HorizontalAlignment == Enum.HorizontalAlignment.Right then
			List.alignX, List.anchorX = UDim.new(1, 0), 1
		else
			List.alignX, List.anchorX = UDim.new(0, 0), 0
		end
		layout:Destroy()
	end
	sf.AutomaticCanvasSize = Enum.AutomaticSize.None

	local padding = sf.UIPadding
	if padding then
		List.padTop, List.padBottom = padding.PaddingTop.Offset, padding.PaddingBottom.Offset
	end

	for _, template in ipairs({ TemplateFirst, TemplateSecond, TemplateThird, TemplateAll }) do
		template.Visible = false
	end

	List.rowH = math.max(1, MeasureHeight(TemplateAll) or 1)
	List.stride = List.rowH + List.gap

	-- local header = sf:WaitForChild(NAMES.Header, 0)
	-- if header and header:IsA("GuiObject") and header.Visible then
	-- 	List.headerH = (MeasureHeight(header) or 0) + List.gap
	-- 	header.AnchorPoint = Vector2.new(List.anchorX, 0)
	-- 	header.Position = UDim2.new(List.alignX.Scale, List.alignX.Offset, 0, 0)
	-- end

	List.topRows = {
		NewRow(TemplateFirst, "TopRow1"),
		NewRow(TemplateSecond, "TopRow2"),
		NewRow(TemplateThird, "TopRow3"),
	}
	MeasureViewport()
	EnsurePoolSize()

	sf:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		FillVisible()
	end)
	sf:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(function()
		-- Fires every frame of the open tween; unscaled height stays the same, so this is cheap.
		if MeasureViewport() then
			EnsurePoolSize()
			List.dirty = true
			FillVisible()
		end
	end)

	-- A manual scroll cancels an auto-scroll instead of fighting it.
	local function onScrollInput(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseWheel or t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			CancelScrollTween()
		end
	end
	sf.InputBegan:Connect(onScrollInput)
	sf.InputChanged:Connect(onScrollInput)

	List.initialized = true
	List.initializing = false
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
		List.dirty = true
		FillVisible(true)

		if SCROLL_TO_SELF_ON_OPEN and not Me.overflow and Me.liveRank > 0 and Me.liveRank <= List.total then
			ScrollToRank(Me.liveRank)
		end
	end)
end

local function BindOpenButton(button)
	if BoundOpenButtons[button] or not button:IsA("GuiButton") then return end
	if not button:IsDescendantOf(PlayerGui) then return end
	BoundOpenButtons[button] = true
	button.Activated:Connect(function()
		RanksController.Toggle()
	end)
end

local function TriggerSider(siderType: string)
	if siderType == "JumpSelf" then
		ScrollToSelf()
	elseif siderType == "JumpTop" then
		ScrollToRank(1)
	elseif siderType == "JumpBottom" then
		ScrollToRank(List.total)
	end

	for _, obj in ipairs(Sider:GetChildren()) do
		if obj:IsA("ImageButton") then
			obj.Image = obj.Name == siderType and  "rbxassetid://72940564227520" or "rbxassetid://85490089980863"
		end
	end
end

ResolveReferences()
--// APIs & Systems
function RanksController.Open()
	IsOpen = true
	SoundService:PlayLocalSound(RankUISound)
	if RanksFrame and not RanksFrame.Visible then
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
	if RanksFrame and RanksFrame.Visible then
		UIInteractionController.ToggleFrame(RanksFrame, false)
	end
end

function RanksController.Toggle()
	if RanksFrame and RanksFrame.Visible then RanksController.Close() else RanksController.Open() end
end

RanksController.ScrollToRank = ScrollToRank
RanksController.ScrollToSelf = ScrollToSelf

function RanksController.Init()
	LeagueInfo:Setup()
	-- RanksFrame.Visible = false
	-- Local player's live state.
	for _, attr in ipairs({ "GlobalRank", "SnapshotRank", "GlobalRankOverflow", GAME_PLAYED_ATTRIBUTE }) do
		PlayerData.Observe(LocalPlayer, attr, ScheduleMeRefresh)
	end
	PlayerData.Observe(LocalPlayer, "Trophies", OnTrophiesChanged)
	PlayerData.Observe(LocalPlayer, "DataLoaded", function()
		LastTrophies = tonumber(PlayerData.Get(LocalPlayer, "Trophies")) or 0 -- baseline: no popup for the load itself
		ScheduleMeRefresh()
	end)
	if PlayerData.Get(LocalPlayer, "DataLoaded") == true then
		LastTrophies = tonumber(PlayerData.Get(LocalPlayer, "Trophies")) or 0
	end

	-- Snapshot version: any change invalidates the page cache.
	ReplicatedValues.GetChangedSignal(ReplicatedStorage, "RanksVersion"):Connect(OnRanksVersionChanged)
	ReplicatedValues.GetChangedSignal(ReplicatedStorage, "RanksTotal"):Connect(OnRanksVersionChanged)

	-- Open / close.
	RanksFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if RanksFrame.Visible then
			OnOpened()
		else
			CancelScrollTween()
		end
	end)
	ConnectButton(ExitButton, RanksController.Close)
	for _, button in ipairs(CollectionService:GetTagged(OPEN_BUTTON_TAG)) do
		task.spawn(BindOpenButton, button)
	end
	CollectionService:GetInstanceAddedSignal(OPEN_BUTTON_TAG):Connect(BindOpenButton)

	-- Floating row and sider jump to positions.
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

	-- League info popup.
	if Panel.InfoButton and LeagueInfo then
		ConnectButton(Panel.InfoButton, function()		
			LeagueInfo:SetVisible(not LeagueInfo.IsVisible)
		end)
	end
	
	ConnectButton(YourRank.LeagueIcon.Button, function()
		LeagueInfo:SetVisible(not LeagueInfo.IsVisible)
	end)

	ConnectButton(RankToggleButton, function()
		if IsOpen then
			RanksController.Close()
		else
			RanksController.Open()
		end
	end)

	ReadMe()
	UpdateLocalPlayerRank()
	UpdateFloatingContent()
	OnRanksVersionChanged()
	TriggerSider("JumpTop")
	if RanksFrame.Visible then OnOpened() end
	RanksController.Close()
	LeagueInfo:Start()
end

return RanksController
