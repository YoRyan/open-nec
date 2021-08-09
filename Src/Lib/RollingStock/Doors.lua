-- Manual door control for rolling stock that supports it, as well as animation
-- control for cab cars.

-- @include Misc.lua

local P = {}
Doors = P

-- From the main coroutine, create a new Doors context.
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _leftanimation = conf.leftanimation,
    _rightanimation = conf.rightanimation,
    _leftopen = false,
    _rightopen = false,
    _lastmanual = nil
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- From the main coroutine, update the door state.
function P:update ()
  local ismanual = RailWorks.GetControlValue("DoorsManual", 0) == 1
  if ismanual ~= self._lastmanual then
    if self._lastmanual ~= nil and RailWorks.GetIsEngineWithKey() then
      if ismanual then
        Misc.showalert("Door Close Control", "Manual")
      else
        Misc.showalert("Door Close Control", "Automatic")
      end
    end
    self._lastmanual = ismanual
  end
  local doclose = RailWorks.GetControlValue("DoorsManualClose", 0) == 1

  local leftopen = RailWorks.GetControlValue("DoorsOpenCloseLeft", 0) == 1
  self._leftopen = leftopen or (ismanual and self._leftopen and not doclose)
  self._leftanimation:setanimatedstate(self._leftopen)

  local rightopen = RailWorks.GetControlValue("DoorsOpenCloseRight", 0) == 1
  self._rightopen = rightopen or (ismanual and self._rightopen and not doclose)
  self._rightanimation:setanimatedstate(self._rightopen)
end

-- Returns true if the lefthand doors are currently open.
function P:isleftdooropen ()
  if self._leftanimation ~= nil then
    return self._leftopen and self._leftanimation:getposition() == 1
  else
    return self._leftopen
  end
end

-- Returns true if the righthand doors are currently open.
function P:isrightdooropen ()
  if self._rightanimation ~= nil then
    return self._rightopen and self._rightanimation:getposition() == 1
  else
    return self._rightopen
  end
end

return P