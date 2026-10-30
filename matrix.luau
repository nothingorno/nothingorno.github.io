local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local MatriX = {}
MatriX.__index = MatriX

type DataPayload = {
	Timestamp: number,
	StateVersion: number,
	RawValues: { [string]: any },
	Sanitized: boolean,
}

function MatriX.new(initialData: { [string]: any }?)
	local self = setmetatable({}, MatriX)
	self._cache = {}
	self._cycleCount = 0
	self._subscribers = {}
	
	if initialData then
		self:WashAndInject(initialData)
	end
	
	return self
end

function MatriX:SanitizeValue(val: any): any
	local valType = typeof(val)
	if valType == "string" then
		return val:gsub("[%z\\1-\\31\\127]", "")
	elseif valType == "number" then
		if val ~= val then return 0 end
		return math.clamp(val, -1e9, 1e9)
	elseif valType == "boolean" or valType == "Vector3" or valType == "CFrame" or valType == "Color3" then
		return val
	elseif valType == "table" then
		local cleaned = {}
		for k, v in pairs(val) do
			cleaned[tostring(k)] = self:SanitizeValue(v)
		end
		return cleaned
	end
	return nil
end

function MatriX:WashAndInject(incomingData: { [string]: any })
	self._cycleCount += 1
	local washedPayload: DataPayload = {
		Timestamp = os.time(),
		StateVersion = self._cycleCount,
		RawValues = {},
		Sanitized = true,
	}

	for key, value in pairs(incomingData) do
		local cleanKey = tostring(key):gsub("[%z\\1-\\31\\127]", "")
		washedPayload.RawValues[cleanKey] = self:SanitizeValue(value)
	end

	self._cache = washedPayload
	self:Broadcast()
end

function MatriX:Cycle()
	if self._cache and self._cache.RawValues then
		self._cycleCount += 1
		self._cache.StateVersion = self._cycleCount
		self._cache.Timestamp = os.time()
	end
end

function MatriX:Subscribe(callback: (payload: DataPayload) -> ())
	table.insert(self._subscribers, callback)
	if self._cache.RawValues then
		task.spawn(callback, self._cache)
	end
end

function MatriX:Broadcast()
	for _, callback in ipairs(self._subscribers) do
		task.spawn(callback, self._cache)
	end
end

function MatriX:GetCleanValue(key: string): any
	if self._cache.RawValues then
		return self._cache.RawValues[key]
	end
	return nil
end

return MatriX
