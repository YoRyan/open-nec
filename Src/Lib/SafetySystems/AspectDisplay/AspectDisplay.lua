-- Base class for an Aspect Display Unit that interfaces with ATC and ACSES.
--
-- @include SafetySystems/CabSignal.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
-- @include YoRyan/LibRailWorks/Units.lua
local P = {}
Adu = P

-- Create a new Adu context.
function P:new(conf)
  local o = {
    _cabsig = CabSignal:new{},
    _getbrakesuppression = conf.getbrakesuppression or
      function() return false end,
    _getacknowledge = conf.getacknowledge or function() return false end,
    _alertlimit_mps = conf.alertlimit_mps or 3 * Units.mph.tomps,
    _penaltylimit_mps = conf.penaltylimit_mps or 6 * Units.mph.tomps,
    _alertwarning_s = conf.alertwarning_s or 7
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt) end

-- Receive a custom signal message.
function P:receivemessage(message) self._cabsig:receivemessage(message) end

-- Get the current speedometer speed.
function P:_getspeed_mps()
  return RailWorks.GetControlValue("SpeedometerMPH", 0) * Units.mph.tomps
end

return P
