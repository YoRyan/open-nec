--[[
  An occupation table for a signal, its approach, and all its links.

                    /----[1]--[tbl 1]-->
  <--[0]--[tbl 0]--------[2]--[tbl 2]-->
                      \--[n]--[tbl n]-->
]]
local P = {}
Occupation = P

local function initstate (self)
  local table = {}
  for i = 0, RailWorks.GetLinkCount() - 1 do
    table[i] = 0
  end
  self._table = table
end

-- Create a new Occupation context.
function P:new ()
  local o = {}
  setmetatable(o, self)
  self.__index = self
  initstate(o)
  return o
end

local function increment (self, t)
  self._table[t] = self._table[t] + 1
end

local function decrement (self, t)
  self._table[t] = math.max(self._table[t] - 1, 0)
end

-- Process and forward an occupation message sent by another signal, or by the
-- game core.
function P:receivemessage (message, parameter, direction, index)
  local function forward ()
    RailWorks.SendSignalMessage(message, parameter, -direction, 1, index)
  end
  if message == RailWorks.sigmessage.OCCUPATION_INCREMENT
      or message == RailWorks.sigmessage.INITIALISE_SIGNAL_TO_BLOCKED then
    increment(self, index)
    if index ~= 0 then
      forward()
    end
  elseif message == RailWorks.sigmessage.OCCUPATION_DECREMENT then
    decrement(self, index)
    if index ~= 0 then
      forward()
    end
  elseif message == RailWorks.sigmessage.RESET_SIGNAL_STATE then
    initstate(self)
  end
end

-- Handle a signal link passage event emitted by PassingLink.
function P:handlelinkevent (event, link)
  if link == 0 then
    if event == PassingLink.event.frontforward then
      increment(self, 0)
    elseif event == PassingLink.event.frontreverse then
      decrement(self, 0)
    elseif event == PassingLink.event.backreverse then
      RailWorks.SendSignalMessage(
        RailWorks.sigmessage.OCCUPATION_INCREMENT, "", -1, 1, 0)
    elseif event == PassingLink.event.backforward then
      RailWorks.SendSignalMessage(
        RailWorks.sigmessage.OCCUPATION_DECREMENT, "", -1, 1, 0)
    end
  else
    if event == PassingLink.event.frontforward then
      increment(self, link)
    elseif event == PassingLink.event.frontreverse then
      decrement(self, link)
    elseif event == PassingLink.event.backreverse then
      increment(self, 0)
    elseif event == PassingLink.event.backforward then
      decrement(self, 0)
    end
  end
end

-- Returns true if the block that corresponds to the provided signal link is
-- clear.
function P:islinkclear (index)
  local link0clear = self._table[0] == 0
  if index == 0 then
    return link0clear
  else
    return link0clear and self._table[index] == 0
  end
end

return P