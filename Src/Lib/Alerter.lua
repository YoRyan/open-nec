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
    minspeed_mps=1*Units.mph.tomps,
    -- The time between alerter sounds.
    countdown_s=60,
    -- The time until a penalty brake is applied.
    alarm_s=6
  }
  self.running = false
  self._sched = scheduler
  self:_initstate()
  return self
end

-- From the main coroutine, initialize this subsystem.
function Alerter.start(self)
  if not self.running then
    self.running = true
    self._coroutines = {self._sched:run(Alerter._run, self)}
  end
end

-- From the main coroutine, halt and reset this subsystem.
function Alerter.stop(self)
  if self.running then
    self.running = false
    for _, co in ipairs(self._coroutines) do
      self._sched:kill(co)
    end
    self:_initstate()
  end
end

function Alerter._initstate(self)
  self.state = {
    -- True when a penalty brake is applied.
    penalty=false,
    -- True when the alarm is sounding.
    alarm=false,
    -- Trigger to acknowledge the alerter.
    acknowledge=Event.new(self._sched)
  }
  self._coroutines = {}
end

function Alerter._run(self)
  while true do
    local countdown = self._sched:select(
      self.config.countdown_s,
      function () return self.state.acknowledge:poll() end,
      function () return self.config.getspeed_mps() < self.config.minspeed_mps end)
    if countdown == nil then
      self.state.alarm = true
      local warning = self._sched:select(
        self.config.alarm_s,
        function () return self.state.acknowledge:poll() end)
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