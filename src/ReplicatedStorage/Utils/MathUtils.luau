--!strict
local MathUtils = {}

local DATE_FORMAT = {
	"mo", "d", "h", "m", "s"
}

--- Convert "anything" to a positive integer, return 0 if invalid
local function TestNumber(t: number): number
    local testT = tonumber(t)

    if not testT or not math.isfinite(t) or t < 0 then
        t = 0
    elseif testT % 1 ~= 0 then
        t = t // 1
    end

    return t
end

--[=[
- Return formatted date with 2 highest level.
- Example: `1d 12h` or `9mo 10d`
]=]
function MathUtils.FormatDate(t: number): string
    t = TestNumber(t)

    -- Let's not adding years here, months is enough...
	local months = t // 2592000 -- 30 days
	local days = (t // 86400) % 30
	local hours = (t // 3600) % 24
	local mins = (t // 60) % 60
	local sec = (t // 1) % 60

	local list = {months, days, hours, mins, sec}

	for i, timeNum in list do
		if timeNum > 0 or i >= #list - 1 then
			local currentFormat = DATE_FORMAT[i]
			local nextFormat = DATE_FORMAT[i + 1]

			local nextNum = list[i + 1]

			return string.format(`%d{currentFormat} %d{nextFormat}`, timeNum, nextNum)
		end
	end

	return ""	-- This is impossible
end

--[=[ 
- Format number into `m:ss` or `mm:ss`
- extended indicated that it will use `h:mm:ss` if possible
]=]
function MathUtils.FormatTime(t: number, extended: boolean?)
    t = TestNumber(t)
    local hours = t // 3600
    local mins = t // 60
    local mins_extended = mins % 60
    local sec = (t // 1) % 60

    if extended and hours > 0 then
        return string.format("%d:%2d:%2d", hours, mins_extended, sec)
    else
        return string.format("%d:%2d", mins, sec)
    end
end

--[=[
- Return the formatted number
- 38699 → "38,699"
]=]
function MathUtils.FormatNumber(n: number): string
	local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

return MathUtils