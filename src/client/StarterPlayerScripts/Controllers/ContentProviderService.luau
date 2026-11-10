--!strict
local Controller = {}

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")


function Controller.Init()
	local VFXsFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("VFX")
	ContentProvider:PreloadAsync(VFXsFolder:GetDescendants())

	local AnimFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Animations")
	ContentProvider:PreloadAsync(AnimFolder:GetDescendants())

	local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
	local RuntimeFolder = ReplicatedStorage:WaitForChild("Runtime")
	local animList = {}
	for _,data in pairs(WeaponConfig.BaseWeapons) do
		local anim = Instance.new("Animation")
		anim.AnimationId = data.Idle
		anim.Parent = RuntimeFolder
		table.insert(animList, anim)

		anim = Instance.new("Animation")
		anim.AnimationId = data.Attack.AnimationId
		anim.Parent = RuntimeFolder
		table.insert(animList, anim)

		anim = Instance.new("Animation")
		anim.AnimationId = data.JumpAttack.AnimationId
		anim.Parent = RuntimeFolder
		table.insert(animList, anim)
	end
	ContentProvider:PreloadAsync(animList)
	for _,anim in ipairs(animList) do
		anim:Destroy()
	end


end

return Controller
