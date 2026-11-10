--!strict
-- One buffer argument per unreliable event. Every record is independently usable.
local Codec = {}
Codec.Version, Codec.HeaderBytes, Codec.RecordBytes = 1, 10, 37
local phases = {"Fly", "Bounce", "Slide", "Rest", "Stun"}
local phaseIds: {[string]: number} = {Fly = 1, Bounce = 2, Slide = 3, Rest = 4, Stun = 5}
-- One authoritative movement sample carried by snapshots or reliable checkpoints.
export type Sample = {
	session: number, -- Unique motion session ID; a new hit creates a new session.
	sequence: number, -- Increasing sample number within the session; rejects older samples.
	control: number, -- Reliable-control version that must arrive before this sample can be used.
	time: number, -- Server timestamp in seconds for this sample.
	position: Vector3, -- World-space center of the authoritative collision sphere, in studs.
	velocity: Vector3, -- World-space scripted velocity, in studs per second.
	phase: string, -- Motion phase at this sample: Stun, Fly, Bounce, Slide, or Rest.
}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function uint(value: number): boolean
	return finite(value) and value >= 0 and value <= 4294967295 and value % 1 == 0
end

local function vector(value: Vector3): boolean
	return finite(value.X) and finite(value.Y) and finite(value.Z)
end

function Codec.Encode(samples: {Sample}, timestamp: number, maxBytes: number): {buffer}
	assert(finite(timestamp) and maxBytes >= 47 and maxBytes <= 850, "Invalid snapshot budget/time")
	local capacity = math.min(255, math.floor((maxBytes - Codec.HeaderBytes) / Codec.RecordBytes))
	local chunks: {buffer} = {}
	for first = 1, #samples, capacity do
		local count = math.min(capacity, #samples - first + 1)
		local data = buffer.create(Codec.HeaderBytes + count * Codec.RecordBytes)
		buffer.writeu8(data, 0, Codec.Version)
		buffer.writeu8(data, 1, count)
		buffer.writef64(data, 2, timestamp)
		for index = 0, count - 1 do
			local sample = samples[first + index]
			assert(uint(sample.session) and sample.session > 0 and uint(sample.sequence) and uint(sample.control)
				and vector(sample.position) and vector(sample.velocity) and phaseIds[sample.phase], "Invalid movement sample")
			local offset = Codec.HeaderBytes + index * Codec.RecordBytes
			buffer.writeu32(data, offset, sample.session)
			buffer.writeu32(data, offset + 4, sample.sequence)
			buffer.writeu32(data, offset + 8, sample.control)
			for component, number in {sample.position.X, sample.position.Y, sample.position.Z,
				sample.velocity.X, sample.velocity.Y, sample.velocity.Z} do
				buffer.writef32(data, offset + 12 + (component - 1) * 4, number)
			end
			buffer.writeu8(data, offset + 36, phaseIds[sample.phase])
		end
		table.insert(chunks, data)
	end
	return chunks
end

function Codec.Decode(data: any): {Sample}?
	if typeof(data) ~= "buffer" or buffer.len(data) < Codec.HeaderBytes or buffer.len(data) > 850 then return nil end
	local count = buffer.readu8(data, 1)
	if buffer.readu8(data, 0) ~= Codec.Version or count == 0
		or buffer.len(data) ~= Codec.HeaderBytes + count * Codec.RecordBytes then return nil end
	local timestamp = buffer.readf64(data, 2)
	if not finite(timestamp) then return nil end
	local samples: {Sample} = {}
	for index = 0, count - 1 do
		local offset = Codec.HeaderBytes + index * Codec.RecordBytes
		local session = buffer.readu32(data, offset)
		local phase = phases[buffer.readu8(data, offset + 36)]
		local position = Vector3.new(buffer.readf32(data, offset + 12), buffer.readf32(data, offset + 16), buffer.readf32(data, offset + 20))
		local velocity = Vector3.new(buffer.readf32(data, offset + 24), buffer.readf32(data, offset + 28), buffer.readf32(data, offset + 32))
		if session == 0 or not phase or not vector(position) or not vector(velocity) then return nil end
		table.insert(samples, {session = session, sequence = buffer.readu32(data, offset + 4),
			control = buffer.readu32(data, offset + 8), time = timestamp, position = position, velocity = velocity, phase = phase})
	end
	return samples
end

return Codec

