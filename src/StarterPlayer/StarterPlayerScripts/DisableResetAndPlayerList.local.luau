local StarterGui = game:GetService("StarterGui")

local function Attempt()
	local success = pcall(function()
		StarterGui:SetCore("ResetButtonCallback", false)
		game.StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
	
	if not success then
		task.wait()
		Attempt()
	end
end


print("Hello, world!")
print("Hello, world!")
print("Hello, world!")
print("Hello, world!")
Attempt()