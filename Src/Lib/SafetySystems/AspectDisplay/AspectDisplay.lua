-- Base class for an Aspect Display Unit that interfaces with ATC and ACSES.
--
-- @include RollingStock/Tone.lua
-- @include Misc.lua
local P = {}
Adu = P

-- From the main coroutine, create a new Adu context. This will add coroutines
-- to the provided scheduler.
function P:new(conf)
  local sched = conf.scheduler
  local o = {
    _sched = sched,
    _cabsig = conf.cabsignal,
    _atc = conf.atc,
    _acses = conf.acses,
    _alert = Tone:new{scheduler = sched, time_s = conf.alert_s or 1}
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Play the speed change informational tone.
function P:triggeralert() self._alert:trigger() end

-- Get the current state of the speed change informational tone.
function P:isalertplaying() return self._alert:isplaying() end

-- Get the current signal speed limit, which is influenced not only by the
-- current cab signal, but also the current state of ACSES.
function P:getsignalspeed_mph()
  local acsesmode = self._acses:getmode()
  local atcspeed_mph = self._atc:getinforcespeed_mph()
  if acsesmode == Acses.mode.positivestop then
    return 0
  elseif acsesmode == Acses.mode.approachmed30 then
    return 30
  elseif atcspeed_mph ~= nil then
    return Misc.round(atcspeed_mph)
  else
    return nil
  end
end

return P
