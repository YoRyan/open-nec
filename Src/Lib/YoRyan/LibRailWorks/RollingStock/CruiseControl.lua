-- PID-based cruise control implementation. For now, it only handles throttle.
-- It reads the player's power setting and outputs its own setting.
--
-- @include YoRyan/LibRailWorks/Units.lua
local P = {}
Cruise = P

-- Create a new CruiseControl context.
function P:new(conf)
  local o = {
    _getplayerthrottle = conf.getplayerthrottle or function() return 0 end,
    _gettargetspeed_mps = conf.gettargetspeed_mps or function() return 0 end,
    _getenabled = conf.getenabled or function() return false end,
    _kp = conf.kp or 1,
    _ki = conf.ki or 0,
    _kd = conf.kd or 0,
    _preverror = 0,
    _integral = 0,
    _throttle = 0
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
-- See https://en.wikipedia.org/wiki/PID_controller#Pseudocode
function P:update(dt)
  if self._getenabled() and dt > 0 then
    local speed_mps = RailWorks.GetControlValue("SpeedometerMPH", 0) *
                        Units.mph.tomps
    local error = self._gettargetspeed_mps() - speed_mps
    self._integral = self._integral + error * dt
    local derivative = (error - self._preverror) / dt
    self._throttle = self._kp * error + self._ki * self._integral + self._kd *
                       derivative
    self._preverror = error
  end
end

-- Get the amount of throttle applied by the cruise control system, from 0 to 1.
function P:getpower()
  local factor = self._getenabled() and self._throttle or 1
  return self._getplayerthrottle() * factor
end

return P
