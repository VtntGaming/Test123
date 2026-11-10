--// Services
local Debris = game:GetService("Debris")

--// Module
local module = {}

function module.Position(pos: Vector3, color: Color3, lifeTime: number, collisionGroup: string?)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Transparency = 0.7
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = CFrame.new(pos)
	p.CastShadow = false
	p.Name = "PositionVisualizer"
	p.Color = color
	p.CollisionGroup = collisionGroup or "Default"
	p.Parent = workspace.Terrain
	Debris:AddItem(p, lifeTime)
end

function module.Space(
	cframe: CFrame,
	size: Vector3,
	name: string,
	color: Color3,
	lifeTime: number,
	collisionGroup: string?
)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Transparency = 0.7
	p.Size = size
	p.CFrame = cframe
	p.CastShadow = false
	p.Name = "SpaceVisualizer"
	p.Color = color
	p.CollisionGroup = collisionGroup or "Default"
	p.Parent = workspace.Terrain
	Debris:AddItem(p, lifeTime)
end

function module.Sphere(position: Vector3, radius: number, name: string, color: Color3, lifeTime: number)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Transparency = 0.25
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one * (radius * 2)
	p.CFrame = CFrame.new(position)
	p.CastShadow = false
	p.Name = name
	p.Color = color
	p.Parent = workspace.Terrain
	Debris:AddItem(p, lifeTime)
end

function module.Cylinder(position: Vector3, radius: number, height: number, name: string, color: Color3, lifeTime: number)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Transparency = 0.25
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(height, radius * 2, radius * 2)
	p.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	p.CastShadow = false
	p.Name = name
	p.Color = color
	p.Parent = workspace.Terrain
	Debris:AddItem(p, lifeTime)
end

function module.Cone(
	origin: Vector3,
	direction: Vector3,
	length: number,
	angle: number,
	name: string,
	color: Color3,
	lifeTime: number
)
	if direction.Magnitude <= 0.001 or length <= 0 or angle <= 0 or angle >= 90 then return end

	local forward = direction.Unit
	local segmentCount = 64
	local segmentLength = length / segmentCount
	local maxRadius = length * math.tan(math.rad(angle))
	local orientation = CFrame.lookAt(Vector3.zero, forward) * CFrame.Angles(math.rad(90), 0, 0)

	for index = 1, segmentCount do
		local progress = index / segmentCount
		local radius = maxRadius * progress
		local center = origin + forward * (segmentLength * (index - 0.5))
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Transparency = 0.7
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(radius * 2, segmentLength * 1.02, radius * 2)
		part.CFrame = CFrame.new(center) * orientation
		part.CastShadow = false
		part.Name = name
		part.Color = color
		part.Parent = workspace.Terrain
		Debris:AddItem(part, lifeTime)
	end
end

function module.Region3(region: Region3, lifeTime: number, collisionGroup: string?)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Transparency = 0.7
	p.Size = region.Size
	p.CFrame = region.CFrame
	p.CastShadow = false
	p.Name = "Region3Visualizer"
	p.CollisionGroup = collisionGroup or "Default"
	p.Parent = workspace.Terrain
	Debris:AddItem(p, lifeTime)
end

function module.Line(
	startPos: Vector3,
	endPos: Vector3,
	thickNess: number,
	color: Color3,
	lifeTime: number,
	collisionGroup: string?
)
	local center = (startPos + endPos) / 2
	local size = (startPos - endPos).Magnitude
	local part = Instance.new("Part")
	part.CFrame = CFrame.lookAt(center, endPos)
	part.Size = Vector3.new(thickNess, thickNess, size)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Name = "LineVisualizer"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CollisionGroup = collisionGroup or "Default"
	part.CastShadow = false
	part.Transparency = 0.7
	part.Parent = workspace.Terrain
	Debris:AddItem(part, lifeTime)
end

local VisualPlacement = require(script.VisualObject.Placement)
local VisualDirection = require(script.VisualObject.Direction)
module.ObjectPlacement = VisualPlacement
module.ObjectDirection = VisualDirection

export type ObjectPlacement = VisualPlacement.Type
export type ObjectDirection = VisualDirection.Type

return module
