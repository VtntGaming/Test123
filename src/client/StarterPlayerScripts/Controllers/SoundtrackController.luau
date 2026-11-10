-- Presents soundtrack controller behavior using logical Player data access.
local SoundtrackController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerData)

-- ==========================================
-- VARIABLES & STATE
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local SoundtrackGroup = SoundService:WaitForChild("Soundtrack")
local LobbyTheme = SoundtrackGroup:WaitForChild("LobbyTheme")
local ArenaTheme = SoundtrackGroup:WaitForChild("ArenaTheme")

-- Fissiamo l'audio nativo a 1.0 (il mixaggio avverrà automaticamente tramite il SoundGroup della Topbar)
local MAX_NATIVE_VOLUME = 1.0 
local FADE_DURATION = 1.5

local currentTrack = nil

-- ==========================================
-- AUDIO LOGIC
-- ==========================================
local function crossfadeTo(targetTrack)
	if currentTrack == targetTrack then return end

	-- Sfuma in uscita la vecchia traccia
	if currentTrack then
		TweenService:Create(currentTrack, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {Volume = 0}):Play()
	end

	-- Prepara e avvia la nuova traccia
	targetTrack.Volume = 0
	if not targetTrack.IsPlaying then
		targetTrack:Play()
	end

	-- Sfuma in entrata la nuova traccia
	TweenService:Create(targetTrack, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {Volume = MAX_NATIVE_VOLUME}):Play()

	local previousTrack = currentTrack
	currentTrack = targetTrack

	-- Ferma la vecchia traccia per risparmiare risorse dopo il fade-out
	if previousTrack then
		task.delay(FADE_DURATION, function()
			if currentTrack ~= previousTrack then
				previousTrack:Stop()
			end
		end)
	end
end

local function updateSoundtrack()
	local isOnArena = PlayerData.Get(LocalPlayer, "IsOnArena")

	if isOnArena then
		crossfadeTo(ArenaTheme)
	else
		crossfadeTo(LobbyTheme)
	end
end

-- ==========================================
-- INIT
-- ==========================================
function SoundtrackController.Init()
	LobbyTheme.Looped = true
	ArenaTheme.Looped = true

	LobbyTheme.Volume = 0
	ArenaTheme.Volume = 0

	LobbyTheme.SoundGroup = SoundtrackGroup
	ArenaTheme.SoundGroup = SoundtrackGroup

	PlayerData.Observe(LocalPlayer, "IsOnArena", updateSoundtrack)

	task.spawn(updateSoundtrack)
end

return SoundtrackController
