-- Alerter implementation with a penalty state.
local P = {}
Alerter = P

local function initstate (self)
  self._running = false
  self._ispenalty = false
  self._isalarm = false
  self._acknowledge = Event:new{scheduler=self._sched}
  self._coroutines = {}
end

-- From the main coroutine, create a new Alerter context. This will add coroutines
-- to the provided scheduler.
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _getspeed_mps = conf.getspeed_mps or function () return 0 end,
    _minspeed_mps = conf.minspeed_mps or 1*Units.mph.tomps,
    _countdown_s = conf.countdown_s or 60,
    _alarm_s = conf.alarm_s or 6
  }
  setmetatable(o, self)
  self.__index = self
  initstate(o)
  return o
end

-- From the main coroutine, start or stop the subsystem based on the provided
-- condition.
function P:setrunstate (cond)
  if cond and not self._running then
    self:start()
  elseif not cond and self._running then
    self:stop()
  end
end

local function penalty (self)
  self._ispenalty = true
  self._sched:select(nil, function ()
    return self._acknowledge:poll() and self._getspeed_mps() < self._minspeed_mps
  end)
  self._ispenalty = false
end

local function run (self)
  while true do
    local countdown = self._sched:select(
      self._countdown_s,
      function () return self._acknowledge:poll() end,
      function () return self._getspeed_mps() < self._minspeed_mps end)
    if countdown == nil then
      self._isalarm = true
      local warning = self._sched:select(
        self._alarm_s,
        function () return self._acknowledge:poll() end)
      if warning == nil then
        penalty(self)
      end
      self._isalarm = false
    end
  end
end

-- From the main coroutine, initialize this subsystem.
function P:start ()
  if not self._running then
    self._running = true
    self._coroutines = {self._sched:run(run, self)}
    if not self._sched:isstartup() then
      self._sched:alert("Alerter", "Cut In")
    end
  end
end

-- From the main coroutine, halt and reset this subsystem.
function P:stop ()
  if self._running then
    self._running = false
    for _, co in ipairs(self._coroutines) do
      self._sched:kill(co)
    end
    initstate(self)
    self._sched:alert("Alerter", "Cut Out")
  end
end

-- Returns true when a penalty brake is applied.
function P:ispenalty ()
  return self._ispenalty
end

-- Returns true when the alarm is applied.
function P:isalarm ()
  return self._isalarm
end

-- Call to acknowledge the alerter.
function P:acknowledge ()
  self._acknowledge:trigger()
end

return P