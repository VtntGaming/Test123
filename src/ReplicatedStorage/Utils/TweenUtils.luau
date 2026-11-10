--!strict
local TweenUtils = {}

export type TweenType = Tween | () -> () | boolean | number

function TweenUtils.PlayTweenSequence(tweens: {TweenType}, await: boolean?): thread?
	local cb = function()
		local nextParallel = false
		for _, tween in ipairs(tweens) do
			local parallelSet = false
			if typeof(tween) == "function" then
				if nextParallel then
					task.spawn(tween)
				else
					pcall(tween)
				end
			elseif typeof(tween) == "Instance" and tween:IsA("Tween") then
				tween:Play()
				if not nextParallel and tween.PlaybackState == Enum.PlaybackState.Playing then
					tween.Completed:Wait()
				end				
			elseif tween == true then
				nextParallel = true
				parallelSet = true
			elseif type(tween) == "number" then
				-- This thing cannot run in parallel
				if tween > 0 then
					task.wait(tween)					
				end
			end
			
			if not parallelSet then				
				nextParallel = false
			end
		end		
	end
	
	if await then
		pcall(cb)
	else
		return task.spawn(cb)
	end

	return nil
end

return TweenUtils