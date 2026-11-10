--!nonstrict
-- BotController (client)
-- Bots are driven by the server (BotService), so the player-only client code never plays their effects.
-- This controller listens to the server's "BotJump" / "BotFx" messages (sent on ActivateAbilityEvent) and plays the
-- SAME VFX / SFX a real player gets, by calling the existing effect modules (JumpEffect, ChargeEffect, PushEffect,
-- PullEffect, ShieldEffect, ChargeVFX). The effect modules key their state by "player", so every bot gets a tiny proxy
-- object ({ Character = model }) instead of a Player.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local Events = ReplicatedStorage:WaitForChild("Events")
local AbilityEvent = Events:WaitForChild("ActivateAbilityEvent")
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))
local SFX = SoundService:WaitForChild("SFX")

local Gameplay = require(script.Parent:WaitForChild("GameplayController"))
local CombatFolder = script.Parent:WaitForChild("CombatController")
local ChargeEffect = require(CombatFolder:WaitForChild("Charge"):WaitForChild("ChargeEffect"))
local PushEffect = require(CombatFolder:WaitForChild("Push"):WaitForChild("PushEffect"))
local PullEffect = require(CombatFolder:WaitForChild("Pull"):WaitForChild("PullEffect"))
local ShieldEffect = require(CombatFolder:WaitForChild("ShieldEffect"))
local ChargeVfx = require(CombatFolder:WaitForChild("ChargeVFX"))

local BotController = {}
local initialized = false
local proxies = setmetatable({}, { __mode = "k" })

local function proxyFor(model)
	local proxy = proxies[model]
	if not proxy then
		proxy = { Character = model, UserId = -1, Name = model.Name }
		proxies[model] = proxy
	end
	return proxy
end

-- 3D sound: a clone parented to the bot, so you hear it where it happens (players' own sounds are global)
local function playSoundAt(name, root)
	local source = SFX:FindFirstChild(name)
	if not source or not source:IsA("Sound") or not root then return end
	local sound = source:Clone()
	sound.Looped = false
	sound.Parent = root
	sound:Play()
	Debris:AddItem(sound, math.max(sound.TimeLength, 1) + 0.5)
end

local function jumpFx(model, isAirJump)
	local root = model and model:FindFirstChild("HumanoidRootPart")
	if not root then return end
	Gameplay.PlayVFX("JumpEffect", root.CFrame)
	playSoundAt(if isAirJump then "DoubleJump" else "Jump", root)
end

-- kind -> handler(model, a, b); mirrors the messages CombatService sends for real players
local Fx = {
	ChargeStart = function(model, duration) ChargeEffect.Start(proxyFor(model), model, duration) end,
	ChargeEnd = function(model) ChargeEffect.Stop(proxyFor(model)) end,
	ChargeImpact = function(model, position) ChargeEffect.Impact(proxyFor(model), position) end,
	PushStart = function(model, params) PushEffect.Cast(proxyFor(model), model, params) end,
	PushImpact = function(model, position) PushEffect.Impact(proxyFor(model), position) end,
	PullStart = function(model, params) PullEffect.Cast(proxyFor(model), model, params) end,
	PullHook = function(model, target, stopPoint) PullEffect.Hook(proxyFor(model), target, stopPoint) end,
}

local function observeBot(model)
	ShieldEffect.Track(model) -- shield bubble follows the ShieldActive attribute
	-- the weapon charge glow players get while holding M1
	model:GetAttributeChangedSignal("IsCharging"):Connect(function()
		if model:GetAttribute("IsCharging") then
			pcall(ChargeVfx.Start, model, GameConfig.Combat.MaxChargeTime)
		else
			pcall(ChargeVfx.Stop, model)
		end
	end)
end

function BotController.Init()
	if initialized then return end
	initialized = true

	AbilityEvent.OnClientEvent:Connect(function(action, a, b, c, d)
		if action == "BotJump" then
			if typeof(a) == "Instance" then jumpFx(a, b == true) end
		elseif action == "BotFx" then
			local handler = Fx[a]
			if handler and typeof(b) == "Instance" and b.Parent then
				local ok, err = pcall(handler, b, c, d)
				if not ok then warn("[BotController]", a, err) end
			end
		end
	end)

	CollectionService:GetInstanceAddedSignal("BotActor"):Connect(observeBot)
	for _, model in CollectionService:GetTagged("BotActor") do task.spawn(observeBot, model) end
end

return BotController
