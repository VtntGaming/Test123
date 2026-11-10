--!strict
-- Evaluates immutable effect timelines identically for fixed gameplay and continuous presentation.

--// Types
export type Falling = {
	-- Seconds of warning before the downward drop begins.
	WarningDuration: number,
	-- Angular rate used by the warning shake oscillations.
	ShakeSpeed: number,
	-- Base warning shake displacement in studs.
	ShakeIntensity: number,
	-- Seconds used to complete the downward drop.
	DropDuration: number,
	-- Total downward displacement in studs.
	DropDistance: number,
}
export type Timelines = {
	-- Returns clamped progress from startedAt to now in seconds; nonpositive duration returns 1.
	Progress: (number, number, number) -> number,
	-- Interpolates from to target over duration seconds, optionally applying quadratic ease-in-out.
	Scale: (number, number, number, number, number, boolean) -> number,
	-- Interpolates from to destination using squared progress over the supplied simulation times in seconds.
	Drop: (CFrame, CFrame, number, number, number) -> CFrame,
	-- Returns a linear shrink factor from 1 to minimum over the supplied simulation times in seconds.
	ArenaScale: (number, number, number, number) -> number,
	-- Offsets origin with a bounded shake and upward drift using elapsed seconds and the falling settings.
	Warning: (CFrame, number, Falling) -> CFrame,
	-- Combines the warning offset with an eased downward drop after WarningDuration, using elapsed seconds.
	Fall: (CFrame, number, Falling) -> CFrame,
}

--// Controller
local Timelines: Timelines = {} :: Timelines

--// APIs
function Timelines.Progress(now, startedAt, duration)
	return if duration > 0 then math.clamp((now - startedAt) / duration, 0, 1) else 1
end

function Timelines.Scale(now, startedAt, duration, from, target, eased)
	local alpha = Timelines.Progress(now, startedAt, duration)
	if eased then
		alpha = if alpha < 0.5 then 2 * alpha * alpha else 1 - (-2 * alpha + 2) ^ 2 / 2
	end
	return from + (target - from) * alpha
end

function Timelines.Drop(from, destination, now, startedAt, duration)
	local alpha = Timelines.Progress(now, startedAt, duration)
	return from:Lerp(destination, alpha * alpha)
end

function Timelines.ArenaScale(now, startedAt, duration, minimum)
	return 1 - Timelines.Progress(now, startedAt, duration) * (1 - minimum)
end

function Timelines.Warning(origin, elapsed, settings)
	local t = math.clamp(elapsed, 0, settings.WarningDuration)
	return origin
		+ Vector3.new(
			math.sin(t * settings.ShakeSpeed) * settings.ShakeIntensity,
			math.cos(t * settings.ShakeSpeed * 1.1) * settings.ShakeIntensity * 0.5 + t * 1.5,
			math.sin(t * settings.ShakeSpeed * 0.9) * settings.ShakeIntensity
		)
end

function Timelines.Fall(origin, elapsed, settings)
	local alpha = Timelines.Progress(elapsed, settings.WarningDuration, settings.DropDuration)
	return Timelines.Warning(origin, elapsed, settings) - Vector3.yAxis * settings.DropDistance * (1 - (1 - alpha) ^ 2)
end

return table.freeze(Timelines)
