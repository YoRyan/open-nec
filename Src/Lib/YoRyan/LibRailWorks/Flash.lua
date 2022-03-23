-- An on-off flash state machine.
--
-- @include YoRyan/LibRailWorks/RailWorks.lua
local P = {}
Flash = P

-- Create a new Flash context.
function P:new(conf)
  local o = {
    _off_s = conf.off_s or 1,
    _on_s = conf.on_s or 1,
    _lastontime_s = nil
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Start or stop the flash sequence based on the provided condition.
function P:setflashstate(cond)
  if cond and self._lastontime_s == nil then
    self._lastontime_s = RailWorks.GetSimulationTime()
  elseif not cond then
    self._lastontime_s = nil
  end
end

-- Returns true if the flasher in the "on" phase.
function P:ison()
  if self._lastontime_s == nil then
    return false
  else
    local now = RailWorks.GetSimulationTime()
    local incycle_s = math.mod(now - self._lastontime_s,
                               self._on_s + self._off_s)
    return incycle_s <= self._on_s
  end
end

-- Returns true if the flasher sequence is running.
function P:getflashstate() return self._lastontime_s ~= nil end

return P
