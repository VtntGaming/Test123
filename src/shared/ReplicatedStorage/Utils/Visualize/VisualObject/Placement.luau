local module = {}
module.constructors = {}
module.methods = {}
module.metatable = { __index = module.methods }

--services
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
--modules
----interface
--constants
local UpVectorType = {
	WorldYAxis = "WorldYAxis",
	HitNormal = "HitNormal"
}
--variable

--
export type Config = {
	Character: Model,
    VisualInstanceTemplate: Model? | BasePart?,
    VisualInstanceSize: (Vector3 | number)?,
	VisualInstanceOffset: CFrame?,
	UpVectorType: string?,
    ColorValid: Color3?,
    ColorInvalid: Color3?,
    Transparency: number?,
	RayValidateFunc: (() -> boolean)?,
	RaycastFunc: () -> RaycastResult?,
}
function module.constructors.new(config: Config)
	local self = setmetatable({}, module.metatable)

	-- public properties
	self.id = HttpService:GenerateGUID(false)
	self.config = config
	self.character = config.Character
    self.visualIns = nil :: (BasePart | Model)?
    self.visualData = {} :: {
		RayResult: RaycastResult?,
		HitCFrame: CFrame?,
		isValid: boolean,
	}
	self.parts = {} :: {BasePart}
	
	-- private field
	type field = {
		tasks: { [string]: thread },
		connections: { [string]: RBXScriptConnection },
	}
	local _private = {
		tasks = {},
		connections = {},
	} :: field
	self._private = _private
	
	return self
end
--private function
local function Visualize(self: Type, enable: boolean)
	local _p = self._private
	local visualData = self.visualData
	local visualIns = self.visualIns
    local offset = self.config.VisualInstanceOffset or CFrame.new()
	local upVectorType = self.config.UpVectorType or UpVectorType.WorldYAxis

	local RENDER_STEP_NAME = `{self.id}.._VisualizeAbility`
	local function Disconnect()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end
	if not enable then
		visualIns.Parent = script
		Disconnect()
		return
	end
    local moveVisualIns = function(cframe: CFrame) end
    if visualIns:IsA("Model") then
        moveVisualIns = function(cframe: CFrame)
            visualIns:PivotTo(cframe)
        end
    elseif visualIns:IsA("BasePart") then
        moveVisualIns = function(cframe: CFrame)
            visualIns.CFrame = cframe
        end
    end
	

	visualIns.Parent = workspace.Terrain
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value - 1, function()
		if not next(self) or not self.character then
			return
		end
		local root = self.character.PrimaryPart
		if not root then
			Disconnect()
			return
		end

		local result = self.config.RaycastFunc()
		if not result then
			visualData.RayResult = nil
			visualData.HitCFrame = nil
			visualIns.Parent = script
			return
		end
		visualIns.Parent = workspace.Terrain

		local valid = if self.config.RayValidateFunc then self.config.RayValidateFunc() else true
		if valid then
			for _,part in ipairs(self.parts) do
				part.Color = self.config.ColorValid or BrickColor.Green().Color
			end
		else
			for _,part in ipairs(self.parts) do
				part.Color = self.config.ColorInvalid or BrickColor.Red().Color
			end
		end

		local upVector: Vector3? = nil
		if upVectorType == UpVectorType.WorldYAxis then
			upVector = Vector3.yAxis
		elseif upVectorType == UpVectorType.HitNormal then
			upVector = result.Normal
		end
		local hitPoint = result.Position
		local rootPos = root.Position
		local hitCFrame = (CFrame.lookAt(hitPoint, Vector3.new(rootPos.X,hitPoint.Y,rootPos.Z), upVector) * CFrame.Angles(0, math.pi, 0))
		moveVisualIns(hitCFrame*offset)
		visualData.HitCFrame = hitCFrame
		visualData.RayResult = result
		visualData.isValid = valid
	end)
end

--properties
module.constructors.UpVectorType = UpVectorType
--class function
function module.methods.Initialize(self: Type)
	local _p = self._private
	local config = self.config
    local visualInsTemplate = config.VisualInstanceTemplate
    local visualInsSize = config.VisualInstanceSize
	local visualInsColor = config.ColorValid or BrickColor.Green().Color
	local visualInsTrans = config.Transparency or 0.75
    local visualIns: Instance
    if visualInsTemplate then
        visualIns = visualInsTemplate:Clone()
    end
    if not visualIns then
        local part = Instance.new("Part")
        part.Size = Vector3.one
        part.Anchored = true
        visualIns = part
    end
	if visualInsSize then
		if visualIns:IsA("BasePart") then
			visualIns.Size = visualInsSize
		elseif visualIns:IsA("Model") then
			if typeof(visualInsSize) == "number" then
				visualIns:ScaleTo(visualInsSize)
			end
		end
	end
    if visualIns:IsA("BasePart") then
		local ins = visualIns
		ins.CanCollide = false
		ins.CanTouch = false
		ins.CanQuery = false
		ins.AudioCanCollide = false
		ins.CastShadow = false
		ins.Anchored = true
		if ins.Transparency ~= 1 then
			ins.Color = visualInsColor
			ins.Transparency = visualInsTrans
			ins.Material = Enum.Material.Neon
			if ins:IsA("MeshPart") then
				ins.TextureID = ""
			end
			table.insert(self.parts, ins)
		end
    end
    
    for _,ins in ipairs(visualIns:GetDescendants()) do
        if ins:IsA("BasePart") then
            ins.CanCollide = false
            ins.CanTouch = false
            ins.CanQuery = false
			ins.AudioCanCollide = false
            ins.CastShadow = false
			ins.Anchored = true
			if ins.Transparency ~= 1 then
				ins.Color = visualInsColor
				ins.Transparency = visualInsTrans
				ins.Material = Enum.Material.Neon
				if ins:IsA("MeshPart") then
					ins.TextureID = ""
				end
				table.insert(self.parts, ins)
			end
        end
    end
	
	
	visualIns.Parent = script

	self.visualIns = visualIns
	
end

function module.methods.Destroy(self: Type)
	local _p = self._private
	for _, task_ in pairs(_p.tasks) do
		if coroutine.status(task_) == "suspended" then
			task.cancel(task_)
		else
			task.defer(function()
				task.cancel(task_)
			end)
		end
	end
	for _, conn in pairs(_p.connections) do
		conn:Disconnect()
	end

	--cleanup
	Visualize(self, false)
	self.visualIns:Destroy()

	table.clear(self)
end

function module.methods.Enable(self: Type)
	local _p = self._private
	Visualize(self,true)
end
function module.methods.Disable(self: Type)
	local _p = self._private
	Visualize(self,false)
	return self:GetVisualData()
end
function module.methods.GetVisualData(self: Type)
	return self.visualData
end
function module.methods.GetVisualInstance(self: Type)
	return self.visualIns
end
export type Type = typeof(module.constructors.new(table.unpack(...)))

return module.constructors
