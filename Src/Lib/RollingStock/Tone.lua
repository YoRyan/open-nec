-- An event-based warning tone that plays a sound for a predefined amount of time.
--
-- @include RailWorks.lua
local P = {}
Tone = P

-- Create a new Tone context.
function P:new(conf)
  local o = {_time_s = conf.time_s or 1, _lastplay_s = nil}
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Trigger the tone. If the sound is already playing, nothing happens.
function P:trigger()
  local now = RailWorks.GetSimulationTime()
  if self._lastplay_s == nil or now - self._lastplay_s > self._time_s then
    self._lastplay_s = now
  end
end

-- Determine whether the underlying sound should play.
function P:isplaying()
  local now = RailWorks.GetSimulationTime()
  return self._lastplay_s ~= nil and now - self._lastplay_s <= self._time_s
end

return P
