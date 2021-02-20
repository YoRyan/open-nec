-- Constants, lookup tables, and code for Amtrak's Advanced Civil Speed
-- Enforcement System.

Acses = {}
Acses.__index = Acses

-- From the main coroutine, create a new Acses context. This will add coroutines
-- to the provided scheduler. The caller should also customize the properties
-- in the config table initialized here.
function Acses.new(scheduler)
  local self = setmetatable({}, Acses)
  self.config = {
    getspeed_mps=function () return 0 end,
    gettrackspeed_mps=function () return 0 end,
    getacknowledge=function () return false end,
    doalert=function () end,
    -- 3 mph
    penaltylimit_mps = 1.34,
    -- 1 mph
    alertlimit_mps = 0.45
  }
  self.state = {
    -- The current track speed in effect.
    enforcedspeed_mps=0,
    -- True when the alarm is sounding continuously.
    alarm=false,
    -- True when a penalty brake is applied.
    penalty=false,

    _violatedspeed_mps=nil
  }
  self._sched = scheduler
  self._sched:run(Acses._setstate, self)
  self._sched:run(Acses._doenforce, self)
  return self
end

function Acses._setstate(self)
  while true do
    if self.state._violatedspeed_mps ~= nil then
      self.state.enforcedspeed_mps = self.state._violatedspeed_mps
    else
      local newspeed_mps = self.config.gettrackspeed_mps()
      if newspeed_mps ~= self.state.enforcedspeed_mps then
        self.config.doalert()
      end
      self.state.enforcedspeed_mps = newspeed_mps
    end
    self._sched:yield()
  end
end

function Acses._doenforce(self)
  while true do
    local speed_mps
    self._sched:yielduntil(function ()
      _, speed_mps = self:_getviolation()
      return speed_mps ~= nil
    end)
    self:_alert(speed_mps)
  end
end

function Acses._alert(self, limit_mps)
  self.state._violatedspeed_mps = limit_mps
  self.state.alarm = true
  local violation, speed_mps
  local acknowledged = false
  repeat
    violation, speed_mps = self:_getviolation()
    acknowledged = acknowledged or self.config.getacknowledge()
    if acknowledged then
      self.state.alarm = false
    end
    if violation == "penalty" then
      self:_penalty(speed_mps)
      -- You have to have acknowledged to get out of the penalty state.
      acknowledged = true
    end
    self._sched:yield()
  until violation == nil and acknowledged
  self.state._violatedspeed_mps = nil
  self.state.alarm = false
end

function Acses._penalty(self, limit_mps)
  self.state.alarm = true
  self.state.penalty = true
  self._sched:yielduntil(function ()
    return self.config.getspeed_mps() <= limit_mps and self.config.getacknowledge()
  end)
  self.state.penalty = false
  self.state.alarm = false
end

function Acses._getviolation(self)
  local speed_mps = self.config.getspeed_mps()
  local trackspeed_mps = self.config.gettrackspeed_mps()
  if speed_mps > trackspeed_mps + self.config.penaltylimit_mps then
    return "penalty", trackspeed_mps
  elseif speed_mps > trackspeed_mps + self.config.alertlimit_mps then
    return "alert", trackspeed_mps
  else
    return nil
  end
end