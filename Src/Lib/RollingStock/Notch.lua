-- Adds virtual notches to a controller by slewing its value to a target, but
-- doing so infrequently enough for the player to still be able to manipulate
-- the control.
local P = {}
Notch = P

-- From the main coroutine, create a new Notch context.
function P:new(conf)
  local o = {
    _sched = conf.scheduler,
    _control = conf.control or "",
    _index = conf.index or 0,
    _gettarget = conf.gettarget or function(value) return value end,
    _lastclock_s = conf.scheduler:clock(),
    _framecount = 0
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- From the main coroutine, update this module every frame.
function P:update()
  if self._framecount >= 15 then
    self._framecount = 0

    local now = self._sched:clock()
    local maxslew = 0.25 / (now - self._lastclock_s)
    self._lastclock_s = now
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
