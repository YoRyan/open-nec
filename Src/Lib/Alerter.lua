-- Alerter implementation with a penalty state.

Alerter = {}
Alerter.__index = Alerter

-- From the main coroutine, create a new Alerter context. This will add coroutines
-- to the provided scheduler. The caller should also customize the properties in
-- the config table initialized here.
function Alerter.new(scheduler)
  local self = setmetatable({}, Alerter)
  self.config = {
    getspeed_mps=function () return 0 end,
    getenabled=function () return false end,
    minspeed_mps=1*Units.mph.tomps,
    -- The time between alerter sounds.
    countdown_s=60,
    -- The time until a penalty brake is applied.
    alarm_s=6
  }
  self.state = {
    -- True when a penalty brake is applied.
    penalty=false,
    -- True when the alarm is sounding.
    alarm=false,
    -- Trigger to acknowledge the alerter.
    acknowledge=Event.new(scheduler)
  }
  self._sched = scheduler
  self._sched:run(Alerter._run, self)
  return self
end

function Alerter._run(self)
  while true do
    self._sched:select(nil, function () return self.config.getenabled() end)
    local countdown = self._sched:select(
      self.config.countdown_s,
      function () return self.state.acknowledge:poll() end,
      function () return self.config.getspeed_mps() < self.config.minspeed_mps end,
      function () return not self.config.getenabled() end)
    if countdown == nil then
      self.state.alarm = true
      local warning = self._sched:select(
        self.config.alarm_s,
        function () return self.state.acknowledge:poll() end,
        function () return not self.config.getenabled() end)
      if warning == nil then
        self:_penalty()
      end
      self.state.alarm = false
    end
  end
end

function Alerter._penalty(self)
  self.state.penalty = true
  self._sched:select(nil, function ()
    return self.state.acknowledge:poll()
      and self.config.getspeed_mps() < self.config.minspeed_mps
  end)
  self.state.penalty = false
end