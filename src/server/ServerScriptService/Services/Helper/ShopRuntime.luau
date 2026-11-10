--!strict
-- Expiring activity tokens, bounded waits and ONE retry scheduler per player.
-- Expiry never deletes a receipt/entitlement. Callers must check tokens after yields.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerData)
local Runtime = {}
type Token = { Deadline: number, AllowDeparted: boolean? }
local locks: { [Player]: { [string]: Token } } = {}
local workers: { [Player]: any } = {}
local steps = { 2, 4, 8, 16, 30, 60 }

function Runtime.Ready(player: Player): boolean
	return player.Parent == Players and PlayerData.Get(player, "DataLoaded") == true
end

function Runtime.Begin(player: Player, key: string, seconds: number?): Token?
	local map = locks[player]
	if not map then
		map = {}
		locks[player] = map
	end
	local old = map[key]
	if old and old.Deadline > os.clock() then
		return nil
	end
	local token = { Deadline = os.clock() + (seconds or 30) }
	map[key] = token
	return token
end

function Runtime.Valid(player: Player, key: string, token: Token): boolean
	return (player.Parent == Players or token.AllowDeparted == true)
		and locks[player] ~= nil
		and locks[player][key] == token
		and os.clock() < token.Deadline
end

function Runtime.Finish(player: Player, key: string, token: Token)
	local map = locks[player]
	if map and map[key] == token then
		map[key] = nil
	end
end

function Runtime.Clear(player: Player, key: string)
	if locks[player] then
		locks[player][key] = nil
	end
end

-- Native network calls cannot be cancelled. Only a current token may act on a result.
function Runtime.Await(seconds: number, callback: () -> ...any): (boolean, ...any)
	local result: any = nil
	local deadline = os.clock() + seconds
	task.spawn(function()
		result = table.pack(pcall(callback))
	end)
	while result == nil and os.clock() < deadline do
		task.wait(0.05)
	end
	if result == nil then
		return false, "TimedOut"
	end
	return table.unpack(result, 1, result.n)
end

function Runtime.Run(player: Player, key: string, callback: (Token) -> (boolean, string?)): (boolean, string?)
	if not Runtime.Ready(player) then
		return false, "DataNotLoaded"
	end
	local token = Runtime.Begin(player, key)
	if not token then
		return false, "Busy"
	end
	local ok, result, reason = Runtime.Await(30, function()
		return callback(token)
	end)
	Runtime.Finish(player, key, token)
	if not ok then
		warn("[ShopRuntime] " .. tostring(result))
		return false, if result == "TimedOut" then "TimedOut" else "RetryLater"
	end
	return result, reason
end

-- A failed job stays queued. Repeated requests replace the same job instead of
-- creating independent retry chains. Round-robin order prevents failed jobs from
-- starving new work while the worker is backed off.
function Runtime.Schedule(player: Player, key: string, callback: () -> boolean)
	if not Runtime.Ready(player) then
		return
	end
	local worker = workers[player]
	if not worker then
		worker = { Jobs = {}, Order = {}, Attempt = 1, Running = false, Generation = 0 }
		workers[player] = worker
	end
	if not worker.Jobs[key] then
		table.insert(worker.Order, key)
	end
	worker.Jobs[key] = callback
	if worker.Running or worker.Scheduled then
		return
	end
	worker.Scheduled = true
	worker.Generation += 1
	local generation = worker.Generation
	local function tick()
		if workers[player] ~= worker or generation ~= worker.Generation then
			return
		end
		if not Runtime.Ready(player) then
			workers[player] = nil
			return
		end
		worker.Scheduled = false
		worker.Running = true
		local remaining = math.min(4, #worker.Order)
		for _ = 1, remaining do
			local jobKey = table.remove(worker.Order, 1)
			local job = worker.Jobs[jobKey]
			local ok, done = Runtime.Await(30, job)
			if workers[player] ~= worker then
				return
			end
			if ok and done and worker.Jobs[jobKey] == job then
				worker.Jobs[jobKey] = nil
			else
				table.insert(worker.Order, jobKey)
			end
			task.wait()
		end
		worker.Running = false
		if next(worker.Jobs) == nil then
			workers[player] = nil
			return
		end
		worker.Attempt = math.min(worker.Attempt + 1, #steps)
		local delayTime = steps[worker.Attempt] * (0.9 + math.random() * 0.2)
		worker.Scheduled = true
		task.delay(delayTime, tick)
	end
	task.delay(steps[1], tick)
end

Players.PlayerRemoving:Connect(function(player)
	locks[player], workers[player] = nil, nil
end)
return Runtime
