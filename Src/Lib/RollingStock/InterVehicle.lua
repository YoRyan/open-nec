-- Inter-vehicle communication throughout a consist. Allows coupled units to
-- send status messages to each other and address each other by position.
--
-- @include Iterator.lua
local P = {}
InterVehicle = P

-- Create a new InterVehicle context.
function P:new(conf)
  local o = {
    _messageid = conf.messageid or 101,
    _expire_s = conf.expire_s or 3,
    _tosend = "",
    _messagesbehind = {},
    _seenbehind = {},
    _messagesahead = {},
    _seenahead = {}
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Set the message to send to the rest of the consist. This must be a string.
function P:setmessage(msg) self._tosend = msg end

-- Get the number of vehicles behind this one.
function P:getnbehind() return table.getn(self._messagesbehind) end

-- Get the message that corresponds to the n'th vehicle behind this one.
function P:getmessagebehind(n) return self._messagesbehind[n] end

-- Get the number of vehicles ahead of this one.
function P:getnahead() return table.getn(self._messagesahead) end

-- Get the message that corresponds to the n'th vehicle ahead of this one.
function P:getmessageahead(n) return self._messagesahead[n] end

local function dropstale(self, messages, seen)
  local now = RailWorks.GetSimulationTime()
  return Iterator.totable(Iterator.filter(function(k, v)
    return now - seen[k] <= self._expire_s
  end, pairs(messages)))
end

-- Update this system once every frame.
function P:update(_)
  local send = "1:" .. self._tosend
  RailWorks.Engine_SendConsistMessage(self._messageid, send, 0)
  RailWorks.Engine_SendConsistMessage(self._messageid, send, 1)

  self._messagesbehind = dropstale(self, self._messagesbehind, self._seenbehind)
  self._messagesahead = dropstale(self, self._messagesahead, self._seenahead)
end

-- Receive a consist message and, if it was processed and shouldn't be forwarded
-- again, return true.
function P:receivemessage(message, argument, direction)
  if message == self._messageid then
    local _, _, nstr, msg = string.find(argument, "^(%d+):(.*)$")
    if nstr ~= nil then
      local n = tonumber(nstr)
      -- Store the received message and set the time last seen.
      local now = RailWorks.GetSimulationTime()
      if direction == 0 then
        self._messagesbehind[n] = msg
        self._seenbehind[n] = now
      elseif direction == 1 then
        self._messagesahead[n] = msg
        self._seenahead[n] = now
      end
      -- Increment and forward to the next car.
      local send = (n + 1) .. ":" .. msg
      RailWorks.Engine_SendConsistMessage(message, send, direction)
      return true
    end
  end
  return false
end

return P
