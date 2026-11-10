local WinnerDanceController = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local WinnerDancesConfig = require(game:GetService("ReplicatedStorage").SharedModules.WinnerDancesConfig)

local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateGameStateEvent = Events:WaitForChild("UpdateGameState")

local SFXGroup = SoundService:WaitForChild("SFX")
local WinnerDanceSound = SFXGroup:WaitForChild("WinnerDance")
local YaySound = SFXGroup:WaitForChild("Yay")

local IntermissionArena = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Intermission"):WaitForChild("IntermissionArena")

WinnerDanceController.IntermissionArena = IntermissionArena
WinnerDanceController.CurrentArenaScale = 1
WinnerDanceController.InitialArenaPivot = nil
WinnerDanceController.InitialArenaData = nil
WinnerDanceController.InitialArenaRadius = nil
WinnerDanceController.WinnerDisplayModel = nil
WinnerDanceController.WinnerDisplayAnimationTrack = nil
local displayRevision = 0

function WinnerDanceController:ClearWinnerDisplay()
	displayRevision += 1 -- Invalidate delayed and yielding display setup before destroying anything.
	if WinnerDanceController.WinnerDisplayAnimationTrack then
		pcall(function()
			WinnerDanceController.WinnerDisplayAnimationTrack:Stop()
			WinnerDanceController.WinnerDisplayAnimationTrack:Destroy()
		end)
		WinnerDanceController.WinnerDisplayAnimationTrack = nil
	end

	if WinnerDanceController.WinnerDisplayModel and WinnerDanceController.WinnerDisplayModel.Parent then
		WinnerDanceController.WinnerDisplayModel:Destroy()
	end
	WinnerDanceController.WinnerDisplayModel = nil
	
	WinnerDanceSound:Stop()
	YaySound:Stop()	
end

function WinnerDanceController:GetArenaTopWinnerDisplayCFrame(winnerClone)
	local arenaCFrame, arenaSize = WinnerDanceController.IntermissionArena:GetBoundingBox()
	local winnerCloneCFrame, winnerCloneSize = winnerClone:GetBoundingBox()

	local arenaCenter = arenaCFrame.Position
	local spawnOnTopArenaY = arenaCFrame.Position.Y + arenaSize.Y / 2 + winnerCloneSize.Y/2 + 18-- adjust depending on how high you want it

	local targetPosition = Vector3.new(
		arenaCenter.X,
		spawnOnTopArenaY,
		arenaCenter.Z
	)

	-- Face one direction, or face toward lobby/camera if you prefer
	return CFrame.new(targetPosition) * CFrame.Angles(0, math.rad(180), 0)
end

function WinnerDanceController:ShowWinnerOnArena(player, scale)
	if not player then warn("ShowWinnerOnArena | Missing player") return nil end

	local character = player.Character
	if not character then warn("ShowWinnerOnArena | Player character missing for ".. player.Name) return nil end

	WinnerDanceController:ClearWinnerDisplay()
	local revision = displayRevision

	local cloneSuccess, winnerClone = pcall(function()
		character.Archivable = true
		local clonedCharacter = character:Clone()
		character.Archivable = false
		return clonedCharacter
	end)

	if not cloneSuccess or not winnerClone then warn("ShowWinnerOnArena | Failed to clone winner character for", player.Name) return nil end

	winnerClone.Name = player.Name.."WinnerDisplay"
	WinnerDanceController.WinnerDisplayModel = winnerClone
	winnerClone.Parent = workspace

	for _, descendant in ipairs(winnerClone:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end

	for _, descendant in ipairs(winnerClone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		elseif descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			descendant.AutoRotate = false
		end
	end

	local rootPart = winnerClone:FindFirstChild("HumanoidRootPart")
	if rootPart then rootPart.Anchored = true end

	scale = scale or 10
	pcall(function() winnerClone:ScaleTo(scale) end)

	local targetCFrame = WinnerDanceController:GetArenaTopWinnerDisplayCFrame(winnerClone)
	winnerClone:PivotTo(targetCFrame)

	-- Wait one frame before playing
	task.wait()
	if revision ~= displayRevision or not winnerClone.Parent then return nil end
	WinnerDanceController:PlayWinnerDanceAnimation(winnerClone, revision)
	if revision ~= displayRevision or not winnerClone.Parent then return nil end

	--SoundService.GameSound.WinningSound.AnimeWowSound:Play()
	WinnerDanceSound:Play()
	--task.delay(WinnerDanceSound.TimeLength*0.7, function() YaySound:Play() end)
	
	WinnerDanceController.WinnerDisplayModel = winnerClone
	return winnerClone
end

function WinnerDanceController:PlayWinnerDanceAnimation(winnerClone, revision)
	if not winnerClone then warn("PlayWinnerDanceAnimation | winnerClone missing") return nil end

	-- Set the Animation Id
	local winnerDances = WinnerDancesConfig.WinnerDances
	if type(winnerDances) ~= "table" or #winnerDances == 0 then warn("PlayWinnerDanceAnimation | GameFlowConfig.WinnerDances is empty or invalid") return nil end

	local randomDanceAnimationId = winnerDances[math.random(1, #winnerDances)]
	if not randomDanceAnimationId then warn("PlayWinnerDanceAnimation | Failed to get random dance animation id") return nil end

	-- Set the Animator
	local humanoid = winnerClone:FindFirstChildOfClass("Humanoid")
	local animationController = winnerClone:FindFirstChildOfClass("AnimationController")
	local animator = nil

	if humanoid then
		animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
	elseif animationController then
		animator = animationController:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = animationController
		end
	else
		warn("PlayWinnerDanceAnimation | No Humanoid or AnimationController found on winner clone")
		return nil
	end

	local animation = Instance.new("Animation")
	animation.Name = "WinnerDanceAnimation"
	animation.AnimationId = "rbxassetid://" .. tostring(randomDanceAnimationId)

	local success, animationTrack = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	animation:Destroy()

	if not success or not animationTrack then warn("PlayWinnerDanceAnimation | Failed to load random animation", tostring(randomDanceAnimationId)) return nil end
	if revision and (revision ~= displayRevision or WinnerDanceController.WinnerDisplayModel ~= winnerClone) then
		animationTrack:Destroy()
		return nil
	end

	animationTrack.Looped = true
	animationTrack.Priority = Enum.AnimationPriority.Action
	animationTrack:Play()

	WinnerDanceController.WinnerDisplayAnimationTrack = animationTrack
	return animationTrack
end

-- Cache initial arena size once
local function cacheInitialArenaSize(arena)
	local modelPivot = arena:GetPivot()
	local originalData = {}

	for _, part in ipairs(arena:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(originalData, {
				Part = part,
				OriginalSize = part.Size,
				RelativeCFrame = modelPivot:ToObjectSpace(part.CFrame),
			})
		end
	end

	return modelPivot, originalData
end

-- Get the top winner display CFrame
function WinnerDanceController:setupOnGameStateEvent()
	local previousState
	UpdateGameStateEvent.OnClientEvent:Connect(function(state, WinnerOrTimer)
		local changed = previousState ~= state
		previousState = state
		if state == "GameOver" then
			WinnerDanceController:ClearWinnerDisplay()
			local revision = displayRevision
			local winner = WinnerOrTimer
			local snapshot: Instance? = nil
			-- A bot winner has no Player: the server sends {Name, Character}. The bot is removed with the arena before the
			-- 2 s delay ends, so snapshot its character right now.
			if typeof(winner) == "table" then
				local source = winner.Character
				if typeof(source) == "Instance" then
					local ok, copy = pcall(function()
						source.Archivable = true
						return source:Clone()
					end)
					snapshot = if ok then copy else nil
				end
				winner = { Name = winner.Name, Character = snapshot }
			end
			task.delay(2, function()
				if revision == displayRevision then
					WinnerDanceController:ShowWinnerOnArena(winner, 16)
				end
				if snapshot then snapshot:Destroy() end
			end)
		elseif state == "Intermission" and typeof(WinnerOrTimer) == "number" then
			if WinnerOrTimer == 0 then
				WinnerDanceController:ClearWinnerDisplay()
			end
		elseif changed and (state == "Waiting" or state == "Starting" or state == "Playing") then
			WinnerDanceController:ClearWinnerDisplay()
		end
	end)
end

function WinnerDanceController:Init()
	WinnerDanceController.InitialArenaPivot, WinnerDanceController.InitialArenaData = cacheInitialArenaSize(WinnerDanceController.IntermissionArena)

	local _, arenaSize = WinnerDanceController.IntermissionArena:GetBoundingBox()
	WinnerDanceController.InitialArenaRadius = math.min(arenaSize.X, arenaSize.Z) / 2 - 0.5
	
	WinnerDanceController:setupOnGameStateEvent()
end

return WinnerDanceController
