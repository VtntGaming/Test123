--!strict
-- Builds one recurring ActiveToday/Earned/Opened funnel per player and UTC day.

--// Types
export type Session = { DayStart: number, Step: number }
export type Event = {
	kind: "Funnel",
	name: string,
	sessionId: string?,
	step: number,
	stepName: string,
	customFields: { [string]: string }?,
}
export type DailyWins = {
	NewSession: () -> Session,
	Record: (
		session: Session,
		userId: number,
		dayStart: number,
		wins: number,
		winsRequired: number,
		claimed: boolean
	) -> { Event },
}

--// Module
local DailyWins = {} :: DailyWins

--// APIs
function DailyWins.NewSession()
	return { DayStart = -1, Step = 0 }
end

function DailyWins.Record(session, userId, dayStart, wins, winsRequired, claimed)
	-- C2: delayed old snapshots cannot reopen an earlier day's funnel.
	if dayStart < session.DayStart then
		return {}
	end
	if dayStart > session.DayStart then
		session.DayStart = dayStart
		session.Step = 0
	end
	local target = if claimed then 3 elseif wins >= winsRequired then 2 else 1
	local names = { "ActiveToday", "Earned", "Opened" }
	local events: { Event } = {}
	for step = session.Step + 1, target do
		table.insert(events, {
			kind = "Funnel",
			name = "DailyWinsDaily_v1",
			sessionId = tostring(userId) .. "-" .. tostring(dayStart),
			step = step,
			stepName = names[step],
			customFields = { [Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = tostring(winsRequired) },
		})
	end
	session.Step = math.max(session.Step, target)
	return events
end

return DailyWins
