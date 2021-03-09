-- Constants, lookup tables, and code for Amtrak's Pennsylvania Railroad-derived
-- pulse code cab signaling and Automatic Train Control system.

Atc = {}
Atc.__index = Atc

Atc.debugsignals = false
Atc.pulsecode = {restrict=0,
                 approach=1,
                 approachmed=2,
                 cabspeed60=3,
                 cabspeed80=4,
                 clear100=5,
                 clear125=6,
                 clear150=7}
Atc.cabspeedflash_s = 0.5
Atc.inittime_s = 3

Atc._naccelsamples = 24
Atc._stopspeed_mps = 0.01

-- From the main coroutine, create a new Atc context. This will add coroutines
-- to the provided scheduler. The caller should also customize the properties
-- in the config table initialized here.
function Atc.new(scheduler)
  local self = setmetatable({}, Atc)
  self.config = {
    getspeed_mps=function () return 0 end,
    getacceleration_mps2=function () return 0 end,
    getacknowledge=function () return false end,
    doalert=function () end,
    countdown_s=6,
    -- Rates fom the Train Sim World: Northeast Corridor New York manual--the
    -- units are given as m/s/s, but such rates would be impossible to achieve,
    -- so I suspect they are supposed to be mph/s.
    suppressing_mps2=-0.5*Units.mph.tomps,
    suppression_mps2=-1.5*Units.mph.tomps,
    speedmargin_mps=3*Units.mph.tomps
  }
  self._sched = scheduler
  self:_initstate()
  return self
end

function Atc._initstate(self)
  self._running = false
  self._isalarm = false
  self._issuppressing = false
  self._issuppression = false
  self._ispenalty = false
  self._pulsecode = Atc.pulsecode.restrict
  self._accelaverage_mps2 = Average.new(Atc._naccelsamples)
  self._enforce = Event:new{scheduler=self._sched}
  self._coroutines = {}
end

-- From the main coroutine, start or stop the subsystem based on the provided
-- condition.
function Atc.setrunstate(self, cond)
  if cond and not self._running then
    self:start()
  elseif not cond and self._running then
    self:stop()
  end
end

-- From the main coroutine, initialize this subsystem.
function Atc.start(self)
  if not self._running then
    self._running = true
    self._coroutines = {
      self._sched:run(Atc._setsuppress, self),
      self._sched:run(Atc._doenforce, self)
    }
    if not self._sched:isstartup() then
      self._sched:alert("ATC Cut In")
    end
  end
end

-- From the main coroutine, halt and reset this subsystem.
function Atc.stop(self)
  if self._running then
    self._running = false
    for _, co in ipairs(self._coroutines) do
      self._sched:kill(co)
    end
    self:_initstate()
    self._sched:alert("ATC Cut Out")
  end
end

-- Get the current pulse code in effect.
function Atc.getpulsecode(self)
  return self._pulsecode
end

-- Returns true when the alarm is sounding.
function Atc.isalarm(self)
  return self._isalarm
end

-- Returns true when the suppressing deceleration rate is achieved.
function Atc.issuppressing(self)
  return self._issuppressing
end

-- Returns true when the suppression deceleration rate is achieved.
function Atc.issuppression(self)
  return self._issuppression
end

-- Returns true when a penalty brake is applied.
function Atc.ispenalty(self)
  return self._ispenalty
end

function Atc._setsuppress(self)
  while true do
    self._accelaverage_mps2:sample(self.config.getacceleration_mps2())
    local accel_mps2 = self._accelaverage_mps2:get()
    if self.config.getspeed_mps() >= 0 then
      self._issuppressing = accel_mps2 <= self.config.suppressing_mps2
      self._issuppression = accel_mps2 <= self.config.suppression_mps2
    else
      self._issuppressing = accel_mps2 >= -self.config.suppressing_mps2
      self._issuppression = accel_mps2 >= -self.config.suppression_mps2
    end
    self._sched:yield()
  end
end

function Atc._doenforce(self)
  while true do
    self._sched:select(
      nil,
      function () return self._enforce:poll() end,
      function () return not self:_iscomplying() end)
    -- Alarm phase. Acknowledge the alarm and reach the initial suppressing
    -- deceleration rate.
    self._isalarm = true
    local acknowledged
    do
      local ack = false
      acknowledged = self._sched:select(
        self.config.countdown_s,
        function ()
          -- The player need only acknowledge the alarm once.
          ack = ack or self.config.getacknowledge()
          return ack and (self._issuppressing or self:_iscomplying())
        end
      ) ~= nil
    end
    if acknowledged then
      -- Suppressing phase. Reach the suppression deceleration rate.
      self._isalarm = false
      local suppressed = self._sched:select(
        self.config.countdown_s,
        function () return self._issuppression end,
        function () return self:_iscomplying() end
      ) ~= nil
      if suppressed then
        -- Suppression phase. Maintain the suppression deceleration rate
        -- until the train complies with the speed limit.
        self._sched:select(
          nil,
          function () return not self._issuppression end,
          function () return self:_iscomplying() end)
        -- From here, return to the beginning of the loop, either to wait for
        -- the next enforcement action or to repeat it immediately.
      else
        self:_penalty()
      end
    else
      self:_penalty()
    end
  end
end

function Atc._iscomplying(self)
  local limit_mps = Atc.getpulsecodespeed_mps(self._pulsecode)
  return self.config.getspeed_mps() <= limit_mps + self.config.speedmargin_mps
end

function Atc._iscomplyingstrict(self)
  local limit_mps = Atc.getpulsecodespeed_mps(self._pulsecode)
  return self.config.getspeed_mps() <= limit_mps
end

-- Get the speed limit, in m/s, that corresponds to a pulse code.
function Atc.getpulsecodespeed_mps(pulsecode)
  if pulsecode == Atc.pulsecode.restrict then
    return 20*Units.mph.tomps
  elseif pulsecode == Atc.pulsecode.approach then
    return 30*Units.mph.tomps
  elseif pulsecode == Atc.pulsecode.approachmed then
    return 45*Units.mph.tomps
  elseif pulsecode == Atc.pulsecode.cabspeed60 then
    return 60*Units.mph.tomps
  elseif pulsecode == Atc.pulsecode.cabspeed80 then
    return 80*Units.mph.tomps
  elseif pulsecode == Atc.pulsecode.clear100 then
    return 100*Units.mph.tomps
  elseif pulsecode == Atc.pulsecode.clear125 then
    return 125*Units.mph.tomps
  elseif pulsecode == Atc.pulsecode.clear150 then
    return 150*Units.mph.tomps
  else
    return nil
  end
end

function Atc._penalty(self)
  self._isalarm = true
  self._ispenalty = true
  self._sched:select(nil, function ()
    return self.config.getspeed_mps() <= Atc._stopspeed_mps
      and self.config.getacknowledge()
  end)
  self._isalarm = false
  self._ispenalty = false
end

-- Receive a custom signal message.
function Atc.receivemessage(self, message)
  if not self._running then
    return
  end
  local newcode = self:_getnewpulsecode(message)
  if newcode < self._pulsecode and not self._sched:isstartup() then
    self._enforce:trigger()
  elseif newcode > self._pulsecode then
    self.config.doalert()
  end
  self._pulsecode = newcode
  if Atc.debugsignals then
    self._sched:info(message)
  end
end

function Atc._getnewpulsecode(self, message)
  local code = self:_messagepulsecode(message)
  if code ~= nil then
    return code
  end
  local power = Power.getchangepoint(message)
  if power ~= nil then
    -- Power switch signal. No change.
    return self._pulsecode
  end
  self._sched:info("WARNING:\nUnknown signal '" .. message .. "'")
  return Atc.pulsecode.restrict
end

function Atc._messagepulsecode(self, message)
  -- Amtrak/NJ Transit signals
  if string.sub(message, 1, 3) == "sig" then
    local code = string.sub(message, 4, 4)
    -- DTG "Clear"
    if code == "1" then
      return Atc.pulsecode.clear125
    elseif code == "2" then
      return Atc.pulsecode.cabspeed80
    elseif code == "3" then
      return Atc.pulsecode.cabspeed60
    -- DTG "Approach Limited (45mph)"
    elseif code == "4" then
      return Atc.pulsecode.approachmed
    -- DTG "Approach Medium (30mph)"
    elseif code == "5" then
      return Atc.pulsecode.approach
    -- DTG "Approach (30mph)"
    elseif code == "6" then
      return Atc.pulsecode.approach
    elseif code == "7" then
      return Atc.pulsecode.restrict
    -- DTG "Ignore"
    elseif code == "8" then
      return self._pulsecode
    else
      return nil
    end
  -- Metro-North signals
  elseif string.find(message, "[MN]") == 1 then
    local code = string.sub(message, 2, 3)
    -- DTG "Clear"
    if code == "10" then
      return Atc.pulsecode.clear125
    -- DTG "Approach Limited (45mph)"
    elseif code == "11" then
      return Atc.pulsecode.approachmed
    -- DTG "Approach Medium (30mph)"
    elseif code == "12" then
      return Atc.pulsecode.approach
    elseif code == "13" or code == "14" then
      return Atc.pulsecode.restrict
    -- DTG "Stop"
    elseif code == "15" then
      return Atc.pulsecode.restrict
    else
      return nil
    end
  else
    return nil
  end
end