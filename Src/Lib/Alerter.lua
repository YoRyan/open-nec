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
  self._sched = scheduler
  self:_initstate()
  return self
end

function Alerter._initstate(self)
  self._running = false
  self._ispenalty = false
  self._isalarm = false
  self._acknowledge = Event.new(self._sched)
  self._coroutines = {}
end

-- From the main coroutine, start or stop the subsystem based on the provided
-- condition.
function Alerter.setrunstate(self, cond)
  if cond and not self._running then
    self:start()
  elseif not cond and self._running then
    self:stop()
  end
end

-- From the main coroutine, initialize this subsystem.
function Alerter.start(self)
  if not self._running then
    self._running = true
    self._coroutines = {self._sched:run(Alerter._run, self)}
    if not self._sched:isstartup() then
      self._sched:alert("Alerter Cut In")
    end
  end
end

-- From the main coroutine, halt and reset this subsystem.
function Alerter.stop(self)
  if self._running then
    self._running = false
    for _, co in ipairs(self._coroutines) do
      self._sched:kill(co)
    end
    self:_initstate()
    self._sched:alert("Alerter Cut Out")
  end
end

-- Returns true when a penalty brake is applied.
function Alerter.ispenalty(self)
  return self._ispenalty
end

-- Returns true when the alarm is applied.
function Alerter.isalarm(self)
  return self._isalarm
end

-- Call to acknowledge the alerter.
function Alerter.acknowledge(self)
  self._acknowledge:trigger()
end

function Alerter._run(self)
  while true do
    local countdown = self._sched:select(
      self.config.countdown_s,
      function () return self._acknowledge:poll() end,
      function () return self.config.getspeed_mps() < self.config.minspeed_mps end)
    if countdown == nil then
      self._isalarm = true
      local warning = self._sched:select(
        self.config.alarm_s,
        function () return self._acknowledge:poll() end)
      if warning == nil then
        self:_penalty()
      end
      self._isalarm = false
    end
  end
end

function Alerter._penalty(self)
  self._ispenalty = true
  self._sched:select(nil, function ()
    return self._acknowledge:poll()
      and self.config.getspeed_mps() < self.config.minspeed_mps
  end)
  self._ispenalty = false
end