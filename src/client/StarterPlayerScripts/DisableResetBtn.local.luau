local StarterGui = game:GetService("StarterGui")

local function Attempt()
	local success = pcall(function()
		StarterGui:SetCore("ResetButtonCallback", false)
	end)
	
	if not success then
		task.wait()
		Attempt()
	end
end

Attempt()