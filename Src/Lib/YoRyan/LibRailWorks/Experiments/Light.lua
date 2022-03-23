-- Continuously turn a light on and off.
--
-- @include YoRyan/LibRailWorks/Misc.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
local P = {}
LightExperiment = P

local onoff_s = 1

-- Create a new LightExperiment context.
function P:new(conf)
  local o = {
    _light = conf.light,
    _lasttime = RailWorks.GetSimulationTime(),
    _show = true
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this experiment once every frame.
function P:update(_)
  local time = RailWorks.GetSimulationTime()
  if time - onoff_s >= self._lasttime then
    self._lasttime = time
    self._show = not self._show
    Call(self._light .. ":Activate", Misc.intbool(self._show))
  end
end

return P
