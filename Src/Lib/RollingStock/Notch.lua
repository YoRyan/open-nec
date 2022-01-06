-- Adds virtual notches to a controller by slewing its value to a target, but
-- doing so infrequently enough for the player to still be able to manipulate
-- the control.
--
-- @include RailWorks.lua
local P = {}
Notch = P

-- Create a new Notch context.
function P:new(conf)
  local o = {
    _control = conf.control or "",
    _index = conf.index or 0,
    _gettarget = conf.gettarget or function(value) return value end,
    _framecount = 0
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt)
  if self._framecount >= 15 then
    self._framecount = 0

    local maxslew = 0.25 / dt
    local curval = RailWorks.GetControlValue(self._control, self._index)
    local target = self._gettarget(curval)
    local newval = target > curval and math.min(target, curval + maxslew) or
                     math.max(target, curval - maxslew)
    RailWorks.SetControlValue(self._control, self._index, newval)
  else
    self._framecount = self._framecount + 1
  end
end

return P
