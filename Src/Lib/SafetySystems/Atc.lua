-- Constants, lookup tables, and code for Amtrak's Pennsylvania Railroad-derived
-- pulse code cab signaling and Automatic Train Control system.
local P = {}
Atc = P

local stopspeed_mps = 0.01

local function initstate (self)
  self._running = false
  self._isalarm = false
  self._ispenalty = false
  self._lastpulsecode = nil
  self._enforce = Event:new{scheduler=self._sched}
  self._coroutines = {}
end

-- From the main coroutine, create a new Atc context.
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _cabsig = conf.cabsignal,
    _getspeed_mps = conf.getspeed_mps or function () return 0 end,
    _getacceleration_mps2 = conf.getacceleration_mps2 or function () return 0 end,
    _getacknowledge = conf.getacknowledge or function () return false end,
    _getpulsecodespeed_mps = conf.getpulsecodespeed_mps or P.amtrakpulsecodespeed_mps,
    _getbrakesuppression = conf.getbrakesuppression or function () return false end,
    _doalert = conf.doalert or function () end,
    _countdown_s = conf.countdown_s or 7,
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

-- Determine whether this system is currently cut in.
function P:isrunning ()
  return self._running
end

local function setstate (self)
  local pulsecode = self._cabsig:getpulsecode()
  if self._lastpulsecode ~= nil and pulsecode < self._lastpulsecode then
    self._enforce:trigger()
  end
  self._lastpulsecode = pulsecode
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
  local limit_mps = self:getinforcespeed_mps()
  return self._getspeed_mps() <= limit_mps + self._speedmargin_mps
end

local function doenforce (self)
  while true do
    self._sched:select(
      nil,
      function () return self._enforce:poll() end,
      function () return not iscomplying(self) end)
    -- Alarm phase. Acknowledge the alarm and place the brakes into
    -- suppression.
    self._isalarm = true
    local acknowledged
    do
      local ack = false
      acknowledged = self._sched:select(
        self._countdown_s,
        function ()
          -- The player need only acknowledge the alarm once.
          ack = ack or self._getacknowledge()
          return ack and (self:issuppression() or iscomplying(self))
        end
      ) ~= nil
    end
    if acknowledged then
      self._isalarm = false
      -- Suppression phase. Maintain this state until the train complies with
      -- the speed limit.
      self._sched:select(
        nil,
        function () return not self:issuppression() end,
        function () return iscomplying(self) end)
      -- From here, return to the beginning of the loop, either to wait for
      -- the next enforcement action or to repeat it immediately.
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
      self._sched:run(setstate, self),
      self._sched:run(doenforce, self)
    }
    if not self._sched:isstartup() then
      self._sched:alert("ATC", "Cut In")
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
    self._sched:alert("ATC", "Cut Out")
  end
end

-- Get the current pulse code aspect in effect.
function P:getpulsecode ()
  if self._running then
    return self._cabsig:getpulsecode()
  else
    return Nec.pulsecode.restrict
  end
end

-- Get the current signal speed limit in force.
function P:getinforcespeed_mps ()
  return self._getpulsecodespeed_mps(self._cabsig:getpulsecode())
end

-- Returns true when the alarm is sounding.
function P:isalarm ()
  return self._isalarm
end

-- Returns true when the suppression state is achieved.
function P:issuppression ()
  return self._getbrakesuppression()
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

-- Get the speed limit, in m/s, that corresponds to a pulse code.
-- Metro-North and LIRR speed limits.
function P.mtapulsecodespeed_mps (pulsecode)
  if pulsecode == Nec.pulsecode.restrict then
    return 15*Units.mph.tomps
  else
    return P.amtrakpulsecodespeed_mps(pulsecode)
  end
end

return P