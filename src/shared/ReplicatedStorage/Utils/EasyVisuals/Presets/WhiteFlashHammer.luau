local RunService = game:GetService("RunService");
local TextEffects = require(script.Parent.Parent);

local INTERVAL = 2;       -- pause after the full sequence (seconds)
local GAP_BETWEEN = -0.75;    -- optional pause between hammer and VFX flash (seconds)
local SCREEN_ANGLE = 180; -- on-screen direction: 0 = left→right, 180 = right→left

local TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.44, 1),
	NumberSequenceKeypoint.new(0.45, 0),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(0.51, 1),
	NumberSequenceKeypoint.new(1, 1)
});

local function createFlash(gui: GuiObject)
	return {
		Gui = gui,
		Gradient = TextEffects.Gradient.new(gui, ColorSequence.new(Color3.fromRGB(255, 255, 255)), TRANSPARENCY),
	};
end

local function setOffset(flash, x: number)
	local inst = flash.Gradient.Instance;
	if (not inst) then
		return;
	end;

	-- Convert the on-screen direction into this image's local space
	local localAngle = SCREEN_ANGLE - flash.Gui.AbsoluteRotation;
	local rad = math.rad(localAngle);

	flash.Gradient.Rotation = localAngle; -- Gradient.lua copies this to Instance.Rotation each frame
	inst.Offset = Vector2.new(math.cos(rad), math.sin(rad)) * x;
end

return function(uiInstance: GuiObject, speed: number, size: number)
	local item = uiInstance:FindFirstChild("Item");
	local vfx = uiInstance:FindFirstChild("VFXBackground");
	local hammerIcon = item and item:FindFirstChild("IconWhite");
	local vfxIcon = vfx and vfx:FindFirstChild("IconWhite");
	assert(hammerIcon, "WhiteFlashHammer: Item.IconWhite not found");
	assert(vfxIcon, "WhiteFlashHammer: VFXBackground.IconWhite not found");

	-- Play order
	local sequence = {
		createFlash(hammerIcon),
		createFlash(vfxIcon),
	};

	-- Build the timeline: one sweep goes from -1 to 1 (2 units) at `speed` units/sec
	local duration = 2 / speed;
	local gap = math.max(GAP_BETWEEN, -duration); -- can't start before the previous one starts
	local lastEnd = 0;

	for i, flash in sequence do
		flash.StartTime = (i - 1) * (duration + gap);
		lastEnd = math.max(lastEnd, flash.StartTime + duration);
		setOffset(flash, -1); -- start hidden
	end;

	local cycleLength = lastEnd + INTERVAL;
	local elapsed = 0;

	local cycle = RunService.Heartbeat:Connect(function(dt)
		if (sequence[1].Gradient.IsPaused) then
			return;
		end;

		elapsed = (elapsed + dt) % cycleLength;

		for _, flash in sequence do
			local t = elapsed - flash.StartTime;
			if (t >= 0 and t < duration) then
				setOffset(flash, -1 + 2 * (t / duration)); -- sweeping
			else
				setOffset(flash, -1); -- parked off-screen
			end;
		end;
	end);

	local effects = {};
	for _, flash in sequence do
		table.insert(effects, flash.Gradient);
	end;

	return {
		Effects = effects,
		Connections = { cycle },
	};
end