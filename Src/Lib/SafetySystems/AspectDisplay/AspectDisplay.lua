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
    _cabsig = conf.cabsignal,
    _atc = conf.atc,
    _acses = conf.acses,
    _atcalert = Tone:new{scheduler = sched, time_s = conf.atcalert_s or 1},
    _acsesalert = Tone:new{scheduler = sched, time_s = conf.acsesalert_s or 1}
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Trigger the ATC alert event.
function P:doatcalert() self._atcalert:trigger() end

-- Trigger the ACSES alert event.
function P:doacsesalert() self._acsesalert:trigger() end

-- Get the current state of the ATC alert tone.
function P:isatcalert() return self._atcalert:isplaying() end

-- Get the current state of the ACSES alert tone.
function P:isacsesalert() return self._acsesalert:isplaying() end

-- Get the current state of the ATC alert/alarm tones.
function P:getatcsound() return
  self._atcalert:isplaying() or self._atc:isalarm() end

-- Get the current state of the ACSES alert/alarm tones.
function P:getacsessound()
  return self._acsesalert:isplaying() or self._acses:isalarm()
end

-- Get the current signal speed limit, which is influenced not only by the
-- current cab signal, but also the current state of ACSES.
function P:getsignalspeed_mph()
  local acsesmode = self._acses:getmode()
  local atcspeed_mps = self._atc:getinforcespeed_mps()
  if acsesmode == Acses.mode.positivestop then
    return 0
  elseif acsesmode == Acses.mode.approachmed30 then
    return 30
  elseif atcspeed_mps ~= nil then
    return Misc.round(atcspeed_mps * Units.mps.tomph)
  else
    return nil
  end
end

return P
