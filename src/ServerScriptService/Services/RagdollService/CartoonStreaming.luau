--!strict
-- Streaming follows a throttled anchor, independently of collision and presentation.
local Workspace = game:GetService("Workspace")
local Replication = {}
local FOCUS_UPDATE_INTERVAL = 0.1 -- Seconds; normal focus movement is at most 10 Hz.
local FOCUS_MAX_LAG = 16 -- Studs; large jumps update immediately to preserve coverage.
local FOCUS_MIN_MOVEMENT = 0.01 -- Studs; avoid publishing unchanged transforms.

export type State = {
	mode: Enum.ModelStreamingMode, -- ModelStreamingMode before knockback started.
	focus: Instance?, -- Player's previous ReplicationFocus, restored only if we still own it.
	anchor: Part?, -- Dedicated focus Part for players; never used for hit or collision queries.
	nextUpdate: number, -- Earliest normal focus-update timestamp; large jumps bypass it.
}

function Replication.Enter(
	character: Model,
	player: Player?,
	position: Vector3,
	parent: Instance
): State?
	if not Workspace.StreamingEnabled then
		return nil
	end
	local saved: State = {
		mode = character.ModelStreamingMode,
		focus = if player then player.ReplicationFocus else nil,
		anchor = nil,
		nextUpdate = Workspace:GetServerTimeNow() + FOCUS_UPDATE_INTERVAL,
	}
	-- Preserve existing model availability; recipient filtering is a separate change.
	character.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	if player then
		local anchor = Instance.new("Part")
		anchor.Name = "CartoonStreamingFocus"
		anchor.Size = Vector3.one
		anchor.Anchored = true
		anchor.Transparency = 1
		anchor.CanCollide, anchor.CanTouch, anchor.CanQuery = false, false, false
		anchor.CastShadow = false
		anchor.CFrame = CFrame.new(position)
		anchor.Parent = parent
		saved.anchor = anchor
		player.ReplicationFocus = anchor
	end
	return saved
end

function Replication.Update(saved: State?, player: Player?, position: Vector3, now: number, force: boolean?)
	local anchor = if saved then saved.anchor else nil
	if
		not saved
		or not anchor
		or not anchor.Parent
		or not player
		or player.ReplicationFocus ~= anchor
	then
		return
	end
	local distance = (position - anchor.Position).Magnitude
	if distance < FOCUS_MIN_MOVEMENT then
		return
	end
	if not force and now < saved.nextUpdate and distance < FOCUS_MAX_LAG then
		return
	end
	anchor.CFrame = CFrame.new(position)
	saved.nextUpdate = now + FOCUS_UPDATE_INTERVAL
end

function Replication.Restore(saved: State?, character: Model, player: Player?)
	if not saved then
		return
	end
	if character.ModelStreamingMode == Enum.ModelStreamingMode.Persistent then
		character.ModelStreamingMode = saved.mode
	end
	local anchor = saved.anchor
	if anchor and player and player.ReplicationFocus == anchor then
		local focus = saved.focus
		player.ReplicationFocus = if focus and focus.Parent then focus else nil
	end
	if anchor then
		anchor:Destroy()
		saved.anchor = nil
	end
end

return Replication
	