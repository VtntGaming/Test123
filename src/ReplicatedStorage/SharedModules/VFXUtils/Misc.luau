local module = {}

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Parentt = workspace.visual

-- SAFE CALL
local function SafeCall(fn)
	local ok, err = pcall(fn)
	if not ok then
		warn("[Misc]", err)
	end
end

-- VFX HANDLE
local TweenService = game:GetService("TweenService")
local Fadetime = 0.25

local function handlevfx(inst, enable)
	if inst:IsA("ParticleEmitter")
		or inst:IsA("PointLight")
		or inst:IsA("SpotLight")
		or inst:IsA("SurfaceLight") then
		inst.Enabled = enable
		return
	end

	if inst:IsA("Beam") then
		if enable then
			inst.Enabled = true

			if inst:GetAttribute("OrigTransparency") then
				inst.Transparency = inst:GetAttribute("OrigTransparency")
				inst.Width0 = inst:GetAttribute("OrigWidth0")
				inst.Width1 = inst:GetAttribute("OrigWidth1")
			end

			return
		end

		if not inst:GetAttribute("OrigTransparency") then
			inst:SetAttribute("OrigTransparency", inst.Transparency)
			inst:SetAttribute("OrigWidth0", inst.Width0)
			inst:SetAttribute("OrigWidth1", inst.Width1)
		end

		local startTime = os.clock()
		local origWidth0 = inst:GetAttribute("OrigWidth0")
		local origWidth1 = inst:GetAttribute("OrigWidth1")

		local conn
		conn = game:GetService("RunService").Heartbeat:Connect(function()
			if not inst or not inst.Parent then
				conn:Disconnect()
				return
			end

			local alpha = (os.clock() - startTime) / Fadetime

			if alpha >= 1 then
				inst.Width0 = 0
				inst.Width1 = 0
				inst.Transparency = NumberSequence.new(1)
				inst.Enabled = false

				conn:Disconnect()
				return
			end

			inst.Width0 = origWidth0 * (1 - alpha)
			inst.Width1 = origWidth1 * (1 - alpha)

			inst.Transparency = NumberSequence.new(alpha)
		end)

		return
	end

	if inst:IsA("Trail") then
		if enable then
			inst.Enabled = true

			if inst:GetAttribute("OrigLifetime") then
				inst.Lifetime = inst:GetAttribute("OrigLifetime")
			end
			return
		end

		if not inst:GetAttribute("OrigLifetime") then
			inst:SetAttribute("OrigLifetime", inst.Lifetime)
		end

		inst.Lifetime = 0
		inst.Enabled = false

		return
	end
end

module.showg = function(gui)
	SafeCall(function()
		for _, df in pairs(gui:GetDescendants()) do
			if df:IsA("ImageButton") then
				local oldd = df.ImageTransparency

				df.ImageTransparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(.25, Enum.EasingStyle.Quad), {ImageTransparency = oldd}):Play()
			end

			if df:IsA("ImageLabel") then
				local oldd = df.ImageTransparency

				df.ImageTransparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(.25, Enum.EasingStyle.Quad), {ImageTransparency = oldd}):Play()
			end

			if df:IsA("Frame") then
				local oldd = df.Transparency

				df.Transparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(.25, Enum.EasingStyle.Quad), {Transparency = oldd}):Play()
			end

			if df:IsA("TextLabel") then
				local oldd = df.TextTransparency

				df.TextTransparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(.25, Enum.EasingStyle.Quad), {TextTransparency = oldd}):Play()
			end

			if df:IsA("UIStroke") then
				local oldd = df.Transparency

				df.Transparency = 1
				game:GetService("TweenService"):Create(df, TweenInfo.new(.25, Enum.EasingStyle.Quad), {Transparency = oldd}):Play()
			end
		end
	end)
end

module.Enable = function(objs, enable)
	SafeCall(function()
		for _, v in pairs(objs) do
			handlevfx(v, enable)
			for _, d in ipairs(v:GetDescendants()) do
				handlevfx(d, enable)
			end
		end
	end)
end

-- TWEEN MODEL
module.TweenModel = function(model, info, cf)
	SafeCall(function()
		local value = Instance.new("CFrameValue")
		value.Value = model:GetPivot()

		value:GetPropertyChangedSignal("Value"):Connect(function()
			model:PivotTo(value.Value)
		end)

		local tween = TweenService:Create(value, info, {Value = cf})
		tween:Play()
		tween.Completed:Once(function()
			value:Destroy()
		end)
	end)
end

-- WELD
module.WeldP = function(model, rootp)
	SafeCall(function()
		local parts = {}
		for _, obj in ipairs(model:GetDescendants()) do
			if obj:IsA("BasePart") then
				obj.Anchored = false
				parts[#parts+1] = obj
			end
		end
		if #parts == 0 then return end

		local root = rootp or parts[math.random(#parts)]
		for _, p in ipairs(parts) do
			if p ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = p
				weld.Parent = root
			end
		end
	end)
end

-- EMIT
module.Emit = function(objs)
	SafeCall(function()
		for _, v in pairs(objs) do
			for _, p in ipairs(v:IsA("ParticleEmitter") and {v} or v:GetDescendants()) do
				if p:IsA("ParticleEmitter") then
					local delayTime = p:GetAttribute("EmitDelay")
					if delayTime then
						task.delay(delayTime, function()
							p:Emit(p:GetAttribute("EmitCount") or 1)
						end)
					else
						p:Emit(p:GetAttribute("EmitCount") or 1)
					end
				end
			end
		end
	end)
end

module.Scale = function(ins, scale)
	if not ins then return end
	SafeCall(function()
		local oldparent = ins.Parent
		local md = Instance.new("Model")
		ins.Parent = md

		md:ScaleTo(scale)
		ins.Parent = oldparent
		md:Destroy()
	end)
end

-- SOUND
module.Sound = function(parent, sound)
	SafeCall(function()
		local ps = game.ReplicatedStorage.Asset.Player.SoundP:Clone()
		ps.Parent = workspace.visual

		if typeof(parent) == "Vector3" then
			ps.Position = parent
		elseif typeof(parent) == "Instance" and parent:IsA("BasePart") then
			ps.Position = parent.Position
		elseif typeof(parent) == "Instance" and parent:IsA("Model") then
			ps.Position = parent:GetPivot().Position
		else
			return
		end

		local sfx = sound:Clone()
		sfx.Parent = ps

		Debris:AddItem(ps, sound.TimeLength*2)
		task.defer(function()
			sfx:Play()
		end)
	end)
end

-- UTILS
module.Debris = function(obj, timee)
	if timee then
		task.delay(timee, function()
			if obj then obj:Destroy() end
		end)
	else
		if obj then obj:Destroy() end
	end
end

module.formattime = function(sec)
	sec = math.floor(tonumber(sec) or 0)
	if sec <= 0 then
		return "0s"
	end

	local days = math.floor(sec / 86400)
	sec = sec % 86400

	local hours = math.floor(sec / 3600)
	sec = sec % 3600

	local mins = math.floor(sec / 60)
	local secs = sec % 60

	local t = {}

	if days > 0 then
		t[#t+1] = days .. "d"
	end
	if hours > 0 then
		t[#t+1] = hours .. "h"
	end
	if mins > 0 then
		t[#t+1] = mins .. "m"
	end
	if secs > 0 or #t == 0 then
		t[#t+1] = secs .. "s"
	end

	return table.concat(t, " ")
end

module.formatclock = function(t)
	t = math.max(0, math.floor(t))

	local h = math.floor(t / 3600)
	local m = math.floor((t % 3600) / 60)
	local s = t % 60

	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	else
		return string.format("%02d:%02d", m, s)
	end
end

module.formatnumber = function(n)
	return tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

module.PMutation = function(name)
	if typeof(name) ~= "string" then
		return {}, name
	end

	local bracket = name:match("^%[(.-)%]")
	if not bracket then
		return {}, name
	end

	local mutations = {}
	for mut in bracket:gmatch("[^,%s]+") do
		mutations[#mutations+1] = mut
	end

	local basename = name:gsub("^%b[]%s*", "")

	return mutations, basename
end

module.CheckP = function(obj, p)
	return pcall(function()
		return obj[p]
	end)
end

module.Bezier = function(p0, p1, p2, t)
	return (1 - t)^2 * p0
		+ 2 * (1 - t) * t * p1
		+ t^2 * p2
end

module.Tween = function(objs, name, instype, info, props)
	SafeCall(function()
		for _, v in pairs(objs) do
			if v:IsA(instype) and (not name or v.Name == name) then
				TweenService:Create(v, info, props):Play()
			end
			for _, o in ipairs(v:GetDescendants()) do
				if o:IsA(instype) and (not name or o.Name == name) then
					TweenService:Create(o, info, props):Play()
				end
			end
		end
	end)
end

return module