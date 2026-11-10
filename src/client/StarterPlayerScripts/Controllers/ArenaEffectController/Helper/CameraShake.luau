-- Client-owned noise shake with explicit teardown and arena eligibility gating.
local CameraShake = {}
CameraShake.__index = CameraShake
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local nextId = 0

function CameraShake.new(eligible)
	nextId += 1
	return setmetatable({ name = "ArenaCameraShake" .. nextId, eligible = eligible, seed = math.random() * 100 }, CameraShake)
end

function CameraShake:_removeOffset()
	if self.camera and self.camera.CFrame == self.applied then
		self.camera.CFrame = self.camera.CFrame * self.offset:Inverse()
	end
	self.camera, self.applied, self.offset = nil, nil, nil
end

function CameraShake:Stop()
	if self.bound then RunService:UnbindFromRenderStep(self.name) end
	self.bound = false
	self:_removeOffset()
end

function CameraShake:Start(duration, intensity, settings)
	self:Stop()
	if self.destroyed or duration <= 0 or intensity <= 0 or not self.eligible() then return end
	self.elapsed = 0
	self.bound = true
	RunService:BindToRenderStep(self.name, Enum.RenderPriority.Camera.Value + 2, function(dt)
		self:_removeOffset()
		self.elapsed += dt
		if self.elapsed >= duration or not self.eligible() then self:Stop() return end
		local camera = Workspace.CurrentCamera
		if not camera then return end
		local edge = math.min(settings.FadeTime, duration * 0.5)
		local fade = if edge > 0 then math.min(self.elapsed / edge, (duration - self.elapsed) / edge, 1) else 1
		local time = self.elapsed * settings.Roughness
		local noise = Vector3.new(math.noise(time, self.seed, 0), math.noise(self.seed, time, 1), math.noise(time, 2, self.seed))
		local position = noise * settings.PositionInfluence * intensity * fade
		local rotation = noise * settings.RotationInfluence * intensity * fade
		self.offset = CFrame.new(position) * CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
		camera.CFrame *= self.offset
		self.camera, self.applied = camera, camera.CFrame
	end)
end

function CameraShake:Destroy()
	self:Stop()
	self.destroyed = true
	self.eligible = nil
end

return CameraShake
