-- PID-based cruise control implementation. For now, it only handles throttle.
local P = {}
Cruise = P

local function run (self)
  -- https://en.wikipedia.org/wiki/PID_controller#Pseudocode
  local prevtime = self._sched:clock()
  local preverror = 0
  local integral = 0
  while true do
    self._sched:select(nil, function () return self._getenabled() end)
    local time = self._sched:clock()
    local dt = time - prevtime
    prevtime = time
    if dt > 0 then
      local error = self._gettargetspeed_mps() - self._getspeed_mps()
      integral = integral + error*dt
      local derivative = (error - preverror)/dt
      self._throttle = self._kp*error + self._ki*integral + self._kd*derivative
      preverror = error
    end
  end
end

-- From the main coroutine, create a new CruiseControl context. This will add
-- coroutines to the provided scheduler.
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _getspeed_mps = conf.getspeed_mps or function () return 0 end,
    _gettargetspeed_mps = conf.gettargetspeed_mps or function () return 0 end,
    _getenabled = conf.getenabled or function () return false end,
    _kp = conf.kp or 1,
    _ki = conf.ki or 0,
    _kd = conf.kd or 0,
    _throttle = 0
  }
  setmetatable(o, self)
  self.__index = self
  o._sched:run(run, o)
  return o
end

-- Get the amount of throttle applied by the cruise control, from 0 to 1.
function P:getthrottle ()
  return self._throttle
end

return P