-- Continuously cycle through an animation.
--
-- @include Misc.lua
-- @include RailWorks.lua
local P = {}
AnimationExperiment = P

-- Create a new AnimationExperiment context.
function P:new(conf)
  local o = {
    _anim = conf.animation,
    _cycle_s = conf.cycle_s or 1,
    _increase = true,
    _lastcycle = RailWorks.GetSimulationTime()
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this experiment once every frame.
function P:update(dt)
  if self._increase then
    RailWorks.AddTime(self._anim, dt)
  else
    RailWorks.AddTime(self._anim, -dt)
  end

  local now = RailWorks.GetSimulationTime()
  if now - self._lastcycle >= self._cycle_s then
    if self._increase then
      Misc.showalert(self._anim, "switching backwards")
    else
      Misc.showalert(self._anim, "switching forwards")
    end
    self._increase = not self._increase
    self._lastcycle = now
  end
end

return P
