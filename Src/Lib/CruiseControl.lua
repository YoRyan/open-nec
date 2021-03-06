-- PID-based cruise control implementation. For now, it only handles throttle.

Cruise = {}
Cruise.__index = Cruise

-- From the main coroutine, create a new CruiseControl context. This will add
-- coroutines to the provided scheduler. The caller should also customize the
-- properties in the config table initialized here.
function Cruise.new(scheduler)
  local self = setmetatable({}, Cruise)
  self.config = {
    getspeed_mps=function () return 0 end,
    gettargetspeed_mps=function () return 0 end,
    getenabled=function () return false end,
    kp=1,
    ki=0,
    kd=0
  }
  self._throttle = 0
  self._sched = scheduler
  self._sched:run(Cruise._run, self)
  return self
end

-- Get the amount of throttle applied by the cruise control, from 0 to 1.
function Cruise.getthrottle(self)
  return self._throttle
end

function Cruise._run(self)
  -- https://en.wikipedia.org/wiki/PID_controller#Pseudocode
  local prevtime = self._sched:clock()
  local preverror = 0
  local integral = 0
  while true do
    self._sched:select(nil, function () return self.config.getenabled() end)
    local time = self._sched:clock()
    local dt = time - prevtime
    prevtime = time
    if dt > 0 then
      local error = self.config.gettargetspeed_mps() - self.config.getspeed_mps()
      integral = integral + error*dt
      local derivative = (error - preverror)/dt
      self._throttle = self.config.kp*error
        + self.config.ki*integral
        + self.config.kd*derivative
      preverror = error
    end
  end
end