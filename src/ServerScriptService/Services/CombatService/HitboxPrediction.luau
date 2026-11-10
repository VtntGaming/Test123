-- Extrapolate client-owned movement using server-observed velocity and network latency.
local HitboxPrediction = {}

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function HitboxPrediction.GetRootCFrame(root, player, settings)
	local frame = root.CFrame
	if not player or not settings.Enable then
		return frame
	end
	-- Server-owned NPCs/characters are already simulated here; predicting them would lead the simulation.
	local ok, ping = pcall(function()
		if root:GetNetworkOwner() ~= player then
			return 0
		end
		return player:GetNetworkPing()
	end)
	if not ok or not finite(ping) or ping <= 0 then
		return frame
	end
	-- GetNetworkPing returns round-trip seconds; approximate the age of incoming movement with half.
	local seconds = math.min(ping * 0.5, settings.MaxPredictionTime)
	local velocity = root.AssemblyLinearVelocity
	if not finite(velocity.X) or not finite(velocity.Y) or not finite(velocity.Z) then
		return frame
	end
	local offset = velocity * seconds
	local distance = offset.Magnitude
	if not finite(distance) then
		return frame
	end
	if distance > settings.MaxOffset then
		offset *= settings.MaxOffset / distance
	end
	-- Translate in world space; retain the server's rotation and the weapon's local hitbox offset.
	return frame + offset
end

return HitboxPrediction
