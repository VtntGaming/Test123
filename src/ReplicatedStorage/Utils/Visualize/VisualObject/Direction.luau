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
    Color: Color3?,
    Transparency: number?,
}
function module.constructors.new(config: Config)
	local self = setmetatable({}, module.metatable)

	-- public properties
	self.id = HttpService:GenerateGUID(false)
	self.config = config
	self.character = config.Character
    self.visualIns = nil :: (BasePart | Model)?
    self.visualData = {} :: {
		hitCFrame: CFrame,
	}
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
local visualizeParams = RaycastParams.new()
visualizeParams.RespectCanCollide = true
local function Visualize(self: Type, enable: boolean)
	local _p = self._private
	local visualData = self.visualData
	local visualIns = self.visualIns
    local offset = self.config.VisualInstanceOffset or CFrame.new()

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
		local hitCFrame = root.CFrame 
		
		moveVisualIns(hitCFrame*offset)
		visualData.hitCFrame = hitCFrame + offset.Position
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
	local visualInsColor = config.Color or BrickColor.Red().Color
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
        visualIns.CanCollide = false
        visualIns.CanTouch = false
        visualIns.CanQuery = false
        visualIns.CastShadow = false
        visualIns.Color = visualInsColor
        visualIns.Transparency = visualInsTrans
        visualIns.Material = Enum.Material.Neon
        if visualIns:IsA("MeshPart") then
            visualIns.TextureID = ""
        end
    end
    
    for _,ins in ipairs(visualIns:GetDescendants()) do
        if ins:IsA("BasePart") then
            ins.CanCollide = false
            ins.CanTouch = false
            ins.CanQuery = false
            ins.CastShadow = false
            ins.Color = visualInsColor
            ins.Transparency = visualInsTrans
            ins.Material = Enum.Material.Neon
            if ins:IsA("MeshPart") then
                ins.TextureID = ""
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
export type Type = typeof(module.constructors.new(table.unpack(...)))

return module.constructors
