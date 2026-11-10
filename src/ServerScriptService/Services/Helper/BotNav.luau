--!nonstrict
-- BotNav
-- Movement + coordination helpers for bots (server only, driven by BotService).
--  * target registry: which bots hunt which actor, so they spread out instead of queueing on one line
--  * ApproachPoint: every bot comes in from its own side of the enemy (separation steering around the target)
--  * Step: walks to a goal. Straight line when it is clear (cheap raycasts, cached), PathfindingService only when a wall
--    or a gap is in the way. Paths are throttled (global concurrency cap, per-bot interval, only when the goal moved),
--    re-planned when blocked, and stuck bots hop / side-step / re-plan.

local PathfindingService = game:GetService("PathfindingService")
local Workspace = game:GetService("Workspace")

local BotNav = {}
local rng = Random.new()
local env = nil -- injected by BotService: { groundAt, refreshRay, rayParams, jump, config }
local attackers = setmetatable({}, { __mode = "k" }) -- [actor Model] = { [botState] = true }
local activeComputes = 0

local AGENT = { AgentRadius = 2.5, AgentHeight = 5.5, AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 6 }
local STUCK_CHECK = 0.7

function BotNav.Init(environment)
	env = environment
end

function BotNav.NewState(now: number)
	return {
		path = nil, waypoints = nil, index = 1, pathGoal = nil, blockedConn = nil,
		computing = false, failures = 0, noPathUntil = 0, nextRepath = 0, repathNow = false,
		directOk = true, directCheckAt = 0, jumpedIndex = 0,
		progressAt = now, progressPos = nil, stuck = 0, lastStepAt = 0,
		sidestepUntil = 0, sidestepDir = Vector3.zero,
	}
end

-- ==========================================
-- TARGET REGISTRY
-- ==========================================
function BotNav.SetTarget(state, actor)
	local previous = state.navTarget
	if previous == actor then return end
	if previous then
		local set = attackers[previous]
		if set then
			set[state] = nil
			if next(set) == nil then attackers[previous] = nil end
		end
	end
	state.navTarget = actor
	if actor then
		local set = attackers[actor]
		if not set then
			set = {}
			attackers[actor] = set
		end
		set[state] = true
	end
end

-- how many OTHER bots are currently hunting `actor`
function BotNav.CountAttackers(actor, except): number
	local set = attackers[actor]
	if not set then return 0 end
	local count = 0
	for other in set do
		if other ~= except then count += 1 end
	end
	return count
end

local function wrapAngle(angle: number): number
	return (angle + math.pi) % (math.pi * 2) - math.pi
end

-- A point around the enemy for this bot to walk to. Starts from the bot's own bearing around the enemy, then pushes it
-- away from the bearings of the other bots hunting the same enemy (+ the bot's personal flank bias).
function BotNav.ApproachPoint(state, enemyPos: Vector3, origin: Vector3, standoff: number): Vector3
	local bearing = math.atan2(origin.Z - enemyPos.Z, origin.X - enemyPos.X)
	local push = state.flankBias or 0
	local set = state.navTarget and attackers[state.navTarget]
	if set then
		local count = 0
		for _ in set do count += 1 end
		if count > 1 then
			local spacing = math.max(0.7, (math.pi * 2 / count) * 0.9)
			for other in set do
				if other ~= state and other.root and other.root.Parent then
					local otherPos = other.root.Position
					local delta = wrapAngle(bearing - math.atan2(otherPos.Z - enemyPos.Z, otherPos.X - enemyPos.X))
					local gap = spacing - math.abs(delta)
					if gap > 0 then
						local sign = if math.abs(delta) < 0.05 then (if state.id < other.id then 1 else -1) else math.sign(delta)
						push += sign * gap * 0.6
					end
				end
			end
		end
	end
	local angle = bearing + push
	return enemyPos + Vector3.new(math.cos(angle), 0, math.sin(angle)) * standoff
end

-- ==========================================
-- WALKING
-- ==========================================
-- Is the straight line to the goal walkable: no wall at body height, ground under it (no void gap)?
local function lineClear(origin: Vector3, goal: Vector3): boolean
	env.refreshRay()
	local delta = Vector3.new(goal.X - origin.X, 0, goal.Z - origin.Z)
	local distance = delta.Magnitude
	if distance < 1 then return true end
	local direction = delta.Unit
	for _, height in { 0, 1.5 } do
		local hit = Workspace:Raycast(origin + Vector3.new(0, height, 0), direction * distance, env.rayParams)
		if hit and hit.Distance < distance - 1.5 then return false end
	end
	local steps = math.clamp(math.floor(distance / 8), 1, 6)
	for i = 1, steps do
		local point = origin + direction * (distance * i / steps)
		if not env.groundAt(Vector3.new(point.X, origin.Y, point.Z)) then return false end
	end
	return true
end

function BotNav.ClearPath(state)
	local nav = state.nav
	if nav.blockedConn then nav.blockedConn:Disconnect(); nav.blockedConn = nil end
	nav.path, nav.waypoints, nav.pathGoal, nav.repathNow = nil, nil, nil, false
end

-- forget everything about the current route (target changed, bot was frozen / knocked back / teleported)
function BotNav.Reset(state)
	BotNav.ClearPath(state)
	local nav = state.nav
	nav.stuck, nav.progressPos, nav.sidestepUntil, nav.directCheckAt = 0, nil, 0, 0
end

function BotNav.Remove(state)
	BotNav.SetTarget(state, nil)
	BotNav.ClearPath(state)
end

local function requestPath(state, origin: Vector3, goal: Vector3, now: number)
	local nav = state.nav
	if nav.computing or activeComputes >= (env.config.MaxPathComputes or 2) then return end
	nav.computing = true
	nav.repathNow = false
	nav.nextRepath = now + rng:NextNumber(env.config.RepathMin or 1, env.config.RepathMax or 1.8)
	activeComputes += 1
	task.spawn(function()
		local path = PathfindingService:CreatePath(AGENT)
		local ok = pcall(path.ComputeAsync, path, origin, goal)
		activeComputes -= 1
		nav.computing = false
		if state.removed then return end
		if ok and path.Status == Enum.PathStatus.Success then
			BotNav.ClearPath(state)
			nav.path, nav.waypoints, nav.index, nav.pathGoal, nav.failures = path, path:GetWaypoints(), 2, goal, 0
			nav.blockedConn = path.Blocked:Connect(function(blockedIndex)
				if blockedIndex >= nav.index then nav.repathNow = true end
			end)
		else
			nav.failures += 1
			nav.waypoints = nil
			-- repeated failures (dynamic arena, no navmesh): walk straight for a while instead of asking again
			if nav.failures >= 3 then nav.noPathUntil, nav.failures = os.clock() + 3, 0 end
		end
	end)
end

-- Walks the bot towards `goal`. Returns "direct" or "path".
function BotNav.Step(state, origin: Vector3, goal: Vector3, now: number, humanoid: Humanoid): string
	local nav = state.nav
	local toGoal = Vector3.new(goal.X - origin.X, 0, goal.Z - origin.Z)
	local distance = toGoal.Magnitude

	-- progress / stuck detection (only counts while this function is called regularly)
	if now - nav.lastStepAt > 0.5 or not nav.progressPos then
		nav.progressAt, nav.progressPos, nav.stuck = now, origin, 0
	end
	nav.lastStepAt = now
	if now - nav.progressAt >= STUCK_CHECK then
		local moved = (origin - nav.progressPos).Magnitude
		nav.progressAt, nav.progressPos = now, origin
		if distance > 5 and moved < 1.2 then
			nav.stuck += 1
			if nav.stuck == 1 then
				env.jump(state, now, true) -- hop over the lip / small obstacle
			elseif nav.stuck == 2 then
				local side = toGoal.Unit:Cross(Vector3.yAxis) * (if rng:NextNumber() < 0.5 then 1 else -1)
				if not env.groundAt(origin + side * 8) then side = -side end
				nav.sidestepDir, nav.sidestepUntil, nav.repathNow = side, now + 0.5, true
			else
				BotNav.ClearPath(state)
				nav.repathNow, nav.stuck, nav.directCheckAt = true, 0, 0
			end
		else
			nav.stuck = 0
		end
	end
	if nav.sidestepUntil > now then
		humanoid:MoveTo(origin + nav.sidestepDir * 8)
		return "path"
	end

	-- straight line when nothing is in the way (re-checked a few times per second, not every tick)
	if now >= nav.directCheckAt then
		nav.directCheckAt = now + 0.25 + rng:NextNumber(0, 0.1)
		nav.directOk = lineClear(origin, goal)
	end
	if nav.directOk or distance < 6 then
		if nav.waypoints then BotNav.ClearPath(state) end
		humanoid:MoveTo(goal)
		return "direct"
	end

	-- blocked: follow a computed path, re-planning only when needed
	local goalMoved = not nav.pathGoal or (goal - nav.pathGoal).Magnitude > (env.config.RepathGoalDistance or 10)
	if (not nav.waypoints or nav.repathNow or (goalMoved and now >= nav.nextRepath)) and now >= nav.noPathUntil then
		requestPath(state, origin, goal, now)
	end

	local waypoints = nav.waypoints
	if not waypoints then
		humanoid:MoveTo(goal) -- no path (yet): keep moving, the stuck logic hops / side-steps
		return "direct"
	end
	local waypoint = waypoints[nav.index]
	while waypoint and Vector3.new(waypoint.Position.X - origin.X, 0, waypoint.Position.Z - origin.Z).Magnitude < 3.5 do
		nav.index += 1
		waypoint = waypoints[nav.index]
	end
	if not waypoint then
		BotNav.ClearPath(state)
		humanoid:MoveTo(goal)
		return "direct"
	end
	if waypoint.Action == Enum.PathWaypointAction.Jump and nav.jumpedIndex ~= nav.index then
		nav.jumpedIndex = nav.index
		env.jump(state, now, false)
	end
	humanoid:MoveTo(waypoint.Position)
	return "path"
end

return BotNav
