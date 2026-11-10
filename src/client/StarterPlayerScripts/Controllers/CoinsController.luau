local CoinsController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")

-- ==========================================
-- VARIABLES & CONFIG
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local SFX = SoundService:WaitForChild("SFX")
local CoinEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("CoinEvent")

local FADE_DISTANCE = 25 
local ROTATION_SPEED = 2 
local DISTANCE_CHECK_INTERVAL = 0.2

local TWEEN_INFO_FADE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_INFO_COLLECT = TweenInfo.new(0.5, Enum.EasingStyle.Bounce, Enum.EasingDirection.In)

local activeTweens = {}
local visibleCoins = {}
local lastDistanceCheck = 0
local moveParts, moveFrames = {}, {}

-- ==========================================
-- INTERNAL FUNCTIONS
-- ==========================================
local function toggleVFX(coinPart, enabled)
	local vfxContainer = coinPart:FindFirstChild("Coin VFX") or coinPart
	for _, vfx in ipairs(vfxContainer:GetDescendants()) do
		if vfx:IsA("ParticleEmitter") then
			vfx.Enabled = enabled
		end
	end
end

local function animateFade(coinPart, targetTransparency)
	if activeTweens[coinPart] then activeTweens[coinPart]:Cancel() end

	local targetAlpha = coinPart:GetAttribute("Collected") and 1 or targetTransparency
	local tween = TweenService:Create(coinPart, TWEEN_INFO_FADE, {Transparency = targetAlpha})
	activeTweens[coinPart] = tween
	tween:Play()

	toggleVFX(coinPart, targetAlpha < 1)
end

local function playCollectAnimation(coinPart)
	if activeTweens[coinPart] then activeTweens[coinPart]:Cancel() end
	toggleVFX(coinPart, false)
	visibleCoins[coinPart] = nil

	local originalPosition = coinPart:GetAttribute("OrigPos") or coinPart.Position
	local originalSize = coinPart:GetAttribute("OrigSize") or coinPart.Size

	local tween = TweenService:Create(coinPart, TWEEN_INFO_COLLECT, {
		Position = originalPosition + Vector3.new(0, 2.5, 0),
		Size = originalSize * 0.01,
		Transparency = 1
	})

	activeTweens[coinPart] = tween
	tween:Play()
	tween.Completed:Wait()

	coinPart.Transparency = 1
	coinPart.Size = originalSize
	coinPart.Position = originalPosition
end

local function setupCoin(coinPart)
	if not coinPart:IsA("BasePart") then return end

	coinPart.Anchored = true
	coinPart.CanCollide = false

	coinPart:SetAttribute("Collected", false)
	coinPart:SetAttribute("OrigPos", coinPart.Position)
	coinPart:SetAttribute("OrigSize", coinPart.Size)
	coinPart:SetAttribute("IsVisible", false)

	coinPart.Transparency = 1
	toggleVFX(coinPart, false)

	coinPart.Touched:Connect(function(hit)
		if coinPart:GetAttribute("Collected") then return end

		local character = hit.Parent
		if not character or character ~= LocalPlayer.Character then return end

		coinPart:SetAttribute("Collected", true)

		local sound = SFX:FindFirstChild("CoinCollect")
		if sound then sound:Play() end

		CoinEvent:FireServer(coinPart)
	end)
end

-- ==========================================
-- INIT
-- ==========================================
function CoinsController.Init()
	for _, coin in ipairs(CollectionService:GetTagged("Coin")) do
		task.spawn(setupCoin, coin)
	end
	CollectionService:GetInstanceAddedSignal("Coin"):Connect(setupCoin)

	CoinEvent.OnClientEvent:Connect(function(actionType, targetPlayer, coinPart)
		if not coinPart then return end

		if actionType == "Collect" then
			coinPart:SetAttribute("Collected", true)
			coinPart.CanTouch = false
			
			task.spawn(playCollectAnimation, coinPart)
		elseif actionType == "Respawn" then
			coinPart:SetAttribute("Collected", false)
			coinPart:SetAttribute("IsVisible", false)
			coinPart.CanTouch = true
			coinPart.Transparency = 1
			visibleCoins[coinPart] = nil
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		local character = LocalPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end

		table.clear(moveParts)
		table.clear(moveFrames)
		for coin, _ in pairs(visibleCoins) do
			if coin.Parent and not coin:GetAttribute("Collected") then
				table.insert(moveParts, coin)
				table.insert(moveFrames, coin.CFrame * CFrame.Angles(0, ROTATION_SPEED * dt, 0))
			else
				visibleCoins[coin] = nil
			end
		end
		if #moveParts > 0 then workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireAllEvents) end

		local now = os.clock()
		if now - lastDistanceCheck >= DISTANCE_CHECK_INTERVAL then
			lastDistanceCheck = now

			local playerPos = rootPart.Position
			for _, coin in ipairs(CollectionService:GetTagged("Coin")) do
				if not coin:GetAttribute("Collected") then
					local distance = (playerPos - coin:GetAttribute("OrigPos")).Magnitude
					local shouldBeVisible = (distance <= FADE_DISTANCE)

					if coin:GetAttribute("IsVisible") ~= shouldBeVisible then
						coin:SetAttribute("IsVisible", shouldBeVisible)

						if shouldBeVisible then
							visibleCoins[coin] = true
							task.spawn(animateFade, coin, 0)
						else
							visibleCoins[coin] = nil
							task.spawn(animateFade, coin, 1)
						end
					end
				end
			end
		end
	end)
end

return CoinsController
