-- Constants, lookup tables, and code for Amtrak's Pennsylvania Railroad-derived
-- pulse code cab signaling and Automatic Train Control system.
local P = {}
Atc = P

local debugsignals = false
local naccelsamples = 24
local stopspeed_mps = 0.01

local function initstate (self)
  self._running = false
  self._isalarm = false
  self._issuppressing = false
  self._issuppression = false
  self._ispenalty = false
  self._pulsecode = Nec.pulsecode.restrict
  self._accelaverage_mps2 = Average:new{nsamples=naccelsamples}
  self._enforce = Event:new{scheduler=self._sched}
  self._coroutines = {}
end

-- From the main coroutine, create a new Atc context. This will add coroutines
-- to the provided scheduler.
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _getspeed_mps = conf.getspeed_mps or function () return 0 end,
    _getacceleration_mps2 = conf.getacceleration_mps2 or function () return 0 end,
    _getacknowledge = conf.getacknowledge or function () return false end,
    _getpulsecodespeed_mps = conf.getpulsecodespeed_mps or P.amtrakpulsecodespeed_mps,
    _doalert = conf.doalert or function () end,
    _countdown_s = conf.countdown_s or 7,
    -- Rates are taken fom the Train Sim World: Northeast Corridor New York manual.
    -- The units are given as m/s/s, but the implied rates would be impossible to
    -- achieve, so I suspect they are supposed to be mph/s.
    _suppressing_mps2 = conf.suppressing_mps2 or -0.5*Units.mph.tomps,
    _suppression_mps2 = conf.suppression_mps2 or -1.5*Units.mph.tomps,
    _speedmargin_mps = conf.speedmargin_mps or 3*Units.mph.tomps
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

local function setsuppress (self)
  while true do
    self._accelaverage_mps2:sample(self._getacceleration_mps2())
    local accel_mps2 = self._accelaverage_mps2:get()
    if self._getspeed_mps() >= 0 then
      self._issuppressing = accel_mps2 <= self._suppressing_mps2
      self._issuppression = accel_mps2 <= self._suppression_mps2
    else
      self._issuppressing = accel_mps2 >= -self._suppressing_mps2
      self._issuppression = accel_mps2 >= -self._suppression_mps2
    end
    self._sched:yield()
  end
end

local function penalty (self)
  self._isalarm = true
  self._ispenalty = true
  self._sched:select(nil, function ()
    return self._getspeed_mps() <= stopspeed_mps and self._getacknowledge()
  end)
  self._isalarm = false
  self._ispenalty = false
end

local function iscomplying (self)
  local limit_mps = self._getpulsecodespeed_mps(self._pulsecode)
  return self._getspeed_mps() <= limit_mps + self._speedmargin_mps
end

local function doenforce (self)
  while true do
    self._sched:select(
      nil,
      function () return self._enforce:poll() end,
      function () return not iscomplying(self) end)
    -- Alarm phase. Acknowledge the alarm and reach the initial suppressing
    -- deceleration rate.
    self._isalarm = true
    local acknowledged
    do
      local ack = false
      acknowledged = self._sched:select(
        self._countdown_s,
        function ()
          -- The player need only acknowledge the alarm once.
          ack = ack or self._getacknowledge()
          return ack and (self._issuppressing or iscomplying(self))
        end
      ) ~= nil
    end
    if acknowledged then
      -- Suppressing phase. Reach the suppression deceleration rate.
      self._isalarm = false
      local suppressed = self._sched:select(
        self._countdown_s,
        function () return self._issuppression end,
        function () return iscomplying(self) end
      ) ~= nil
      if suppressed then
        -- Suppression phase. Maintain the suppression deceleration rate
        -- until the train complies with the speed limit.
        self._sched:select(
          nil,
          function () return not self._issuppression end,
          function () return iscomplying(self) end)
        -- From here, return to the beginning of the loop, either to wait for
        -- the next enforcement action or to repeat it immediately.
      else
        penalty(self)
      end
    else
      penalty(self)
    end
  end
end

-- From the main coroutine, initialize this subsystem.
function P:start ()
  if not self._running then
    self._running = true
    self._coroutines = {
      self._sched:run(setsuppress, self),
      self._sched:run(doenforce, self)
    }
    if not self._sched:isstartup() then
      self._sched:alert("ATC Cut In")
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
    self._sched:alert("ATC Cut Out")
  end
end

-- Get the current pulse code in effect.
function P:getpulsecode ()
  return self._pulsecode
end

-- Get the current signal speed limit in force.
function P:getinforcespeed_mps ()
  return self._getpulsecodespeed_mps(self._pulsecode)
end

-- Returns true when the alarm is sounding.
function P:isalarm ()
  return self._isalarm
end

-- Returns true when the suppressing deceleration rate is achieved.
function P:issuppressing ()
  return self._issuppressing
end

-- Returns true when the suppression deceleration rate is achieved.
function P:issuppression ()
  return self._issuppression
end

-- Returns true when a penalty brake is applied.
function P:ispenalty ()
  return self._ispenalty
end

-- Get the speed limit, in m/s, that corresponds to a pulse code.
-- Amtrak speed limits.
function P.amtrakpulsecodespeed_mps (pulsecode)
  if pulsecode == Nec.pulsecode.restrict then
    return 20*Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.approach then
    return 30*Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.approachmed then
    return 45*Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.cabspeed60 then
    return 60*Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.cabspeed80 then
    return 80*Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.clear100 then
    return 100*Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.clear125 then
    return 125*Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.clear150 then
    return 150*Units.mph.tomps
  else
    return nil
  end
end

local function topulsecode (self, message)
  -- Amtrak/NJ Transit signals
  if string.sub(message, 1, 3) == "sig" then
    local code = string.sub(message, 4, 4)
    -- DTG "Clear"
    if code == "1" then
      return Nec.pulsecode.clear125
    elseif code == "2" then
      return Nec.pulsecode.cabspeed80
    elseif code == "3" then
      return Nec.pulsecode.cabspeed60
    -- DTG "Approach Limited (45mph)"
    elseif code == "4" then
      return Nec.pulsecode.approachmed
    -- DTG "Approach Medium (30mph)"
    elseif code == "5" then
      return Nec.pulsecode.approach
    -- DTG "Approach (30mph)"
    elseif code == "6" then
      return Nec.pulsecode.approach
    elseif code == "7" then
      return Nec.pulsecode.restrict
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
      return Nec.pulsecode.clear125
    -- DTG "Approach Limited (45mph)"
    elseif code == "11" then
      return Nec.pulsecode.approachmed
    -- DTG "Approach Medium (30mph)"
    elseif code == "12" then
      return Nec.pulsecode.approach
    elseif code == "13" or code == "14" then
      return Nec.pulsecode.restrict
    -- DTG "Stop"
    elseif code == "15" then
      return Nec.pulsecode.restrict
    else
      return nil
    end
  else
    return nil
  end
end

local function getnewpulsecode (self, message)
  local code = topulsecode(self, message)
  if code ~= nil then
    return code
  end
  local power = Power.getchangepoint(message)
  if power ~= nil then
    -- Power switch signal. No change.
    return self._pulsecode
  end
  self._sched:info("WARNING:\nUnknown signal '" .. message .. "'")
  return Nec.pulsecode.restrict
end

-- Receive a custom signal message.
function P:receivemessage (message)
  if not self._running then
    return
  end
  local newcode = getnewpulsecode(self, message)
  if newcode < self._pulsecode and not self._sched:isstartup() then
    self._enforce:trigger()
  elseif newcode > self._pulsecode then
    self._doalert()
  end
  self._pulsecode = newcode
  if debugsignals then
    self._sched:alert(message)
  end
end

return P