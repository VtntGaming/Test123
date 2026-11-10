--[[
	by YuriD😼💗

	tween template
	local twp1 = {
		{ins = workspace.Part, twinfo = TweenInfo.new(1, Enum.EasingStyle.Linear), 
			prop = {Size = Vector3.one*10}, times = .8},
		{ins = workspace.Part, twinfo = TweenInfo.new(.5, Enum.EasingStyle.Linear), 
			prop = {Transparency = 1}},
	}
	
	ins = Instance
	twinfo = TweenInfo
	prop = Properties
	times = times play --no times => times = tweeninfo time

	local TweenM = require(.TweenM)
	local pack = TweenM.new(twp1)

	-- sync false
	pack:Play(true)

	-- sync true
	pack:Play(false)
	print("vfx done")

	-- cancel tweenm
	pack:Cancel()
]]

local TweenService = game:GetService("TweenService")
local tweenm = {}
tweenm.__index = tweenm

-- check
local function validst(step)
	if typeof(step) ~= "table" then return false end
	if not step.ins or typeof(step.ins) ~= "Instance" then return false end
	if not step.twinfo or typeof(step.twinfo) ~= "TweenInfo" then return false end
	if not step.prop or typeof(step.prop) ~= "table" then return false end
	return true
end

-- createnew
function tweenm.new(pack)
	assert(typeof(pack) == "table", "pack must be table!?!?!!?!!!!")

	return setmetatable({
		pack = pack,
		running = false,
		cancelled = false,
		tweens = {},
		onstart = nil,
		onstep = nil,
		oncomplete = nil,
	}, tweenm)
end

-- play tween step
function tweenm:_playstep(step)
	if not validst(step) then return end
	--if not step.ins:IsDescendantOf(game) then return end
	if self.cancelled then return end

	local tw = game:GetService("TweenService"):Create(step.ins, step.twinfo, step.prop)
	table.insert(self.tweens, tw)

	if self.onstep then
		pcall(self.onstep, step, tw)
	end

	tw:Play()

	if step.nowait then
		return
	end

	if typeof(step.times) == "number" then
		task.wait(step.times)
	else
		tw.Completed:Wait()
	end
end

-- runner
function tweenm:_run()
	self.running = true
	self.cancelled = false
	table.clear(self.tweens)

	if self.onstart then
		pcall(self.onstart)
	end

	for _, step in ipairs(self.pack) do
		if self.cancelled then break end

		-- delay step
		if typeof(step.delay) == "number" then
			task.wait(math.max(step.delay, 0))
		end

		if step.parallel and typeof(step.parallel) == "table" then
			local threads = {}

			for _, pstep in ipairs(step.parallel) do
				table.insert(threads, task.spawn(function()
					self:_playstep(pstep)
				end))
			end

			if not step.nowait then
				for _, th in ipairs(threads) do
					task.wait()
				end
			end
		else
			self:_playstep(step)
		end
	end

	self.running = false

	if not self.cancelled and self.oncomplete then
		pcall(self.oncomplete)
	end
end

-- public api
function tweenm:Play(async)
	if self.running then return end

	if async then
		task.spawn(function()
			self:_run()
		end)
	else
		self:_run()
	end
end

function tweenm:Cancel()
	if self.cancelled then return end
	self.cancelled = true

	for _, tw in ipairs(self.tweens) do
		pcall(tw.Cancel, tw)
	end

	table.clear(self.tweens)
end

return tweenm