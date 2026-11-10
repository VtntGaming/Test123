local Controller = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local DataStoreService = game:GetService("DataStoreService")
-- ==========================================
-- STATE & VARIABLES
-- ==========================================
local store = DataStoreService:GetDataStore("NextUpdate")
local nextUpdateDate = DateTime.fromUniversalTime(2026,11,7,17-7)
local FORCE_RESET = false
-- ==========================================
-- INIT
-- ==========================================
function Controller.Init()
	task.spawn(function()
		local success,result = false, nil
		while not success do
			success,result = pcall(function()
				return store:GetAsync("NextUpdate")
			end)
			if not success then
				warn(result)
				task.wait(5)
			else
				if not result or FORCE_RESET then
					success,result = pcall(function()
						local timeStamp = nextUpdateDate.UnixTimestamp
						store:UpdateAsync("NextUpdate", function(value)
							if value and not FORCE_RESET then -- some server overwrite it
								return
							end
							return timeStamp
						end)
						return timeStamp
					end)
					if not success then
						warn(result)
						task.wait(5)
					end
				end
			end
		end
		if result and typeof(result) == "number" then
			workspace:SetAttribute("NextUpdate", result)
		else
			warn(`Invalid result: {result} type: {if result then typeof(result) else "unknown"}`)
		end
	end)
end

return Controller