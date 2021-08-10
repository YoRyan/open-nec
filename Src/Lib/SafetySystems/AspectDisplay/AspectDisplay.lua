-- Base class for an Aspect Display Unit that interfaces with ATC and ACSES.

-- @include RollingStock/Tone.lua
-- @include Misc.lua

local P = {}
Adu = P

-- From the main coroutine, create a new Adu context. This will add coroutines
-- to the provided scheduler.
function P:new (conf)
  local sched = conf.scheduler
  local o = {
    _cabsig = conf.cabsignal,
    _atc = conf.atc,
    _acses = conf.acses,
    _atcalert = Tone:new{
      scheduler = sched,
      time_s = conf.atcalert_s or 1
    },
    _acsesalert = Tone:new{
      scheduler = sched,
      time_s = conf.acsesalert_s or 1
    }
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Trigger the ATC alert event.
function P:doatcalert ()
  self._atcalert:trigger()
end

-- Trigger the ACSES alert event.
function P:doacsesalert ()
  self._acsesalert:trigger()
end

-- Get the current state of the ATC alert tone.
function P:isatcalert ()
  return self._atcalert:isplaying()
end

-- Get the current state of the ACSES alert tone.
function P:isacsesalert ()
  return self._acsesalert:isplaying()
end

-- Get the current state of the ATC alert/alarm tones.
function P:getatcsound ()
  return self._atcalert:isplaying() or self._atc:isalarm()
end

-- Get the current state of the ACSES alert/alarm tones.
function P:getacsessound ()
  return self._acsesalert:isplaying() or self._acses:isalarm()
end

-- Get the current state of the ATC indicator light.
function P:getatcindicator ()
  local atcspeed_mps = self._atc:getinforcespeed_mps()
  local acsesspeed_mps = self._acses:getinforcespeed_mps()
  return atcspeed_mps ~= nil
    and Misc.round(atcspeed_mps * Units.mps.tomph) ~= 150
    and (acsesspeed_mps == nil or atcspeed_mps <= acsesspeed_mps)
end

-- Get the current state of the ACSES indicator light.
function P:getacsesindicator ()
  local atcspeed_mps = self._atc:getinforcespeed_mps()
  local acsesspeed_mps = self._acses:getinforcespeed_mps()
  return acsesspeed_mps ~= nil
    and (atcspeed_mps == nil
           or Misc.round(atcspeed_mps * Units.mps.tomph) == 150
           or acsesspeed_mps < atcspeed_mps)
end

-- Get the current signal speed limit.
function P:getsignalspeed_mph ()
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

-- Get the current civil (track) speed limit.
function P:getcivilspeed_mph ()
  local acsesspeed_mps = self._acses:getinforcespeed_mps()
  if acsesspeed_mps ~= nil then
    return Misc.round(acsesspeed_mps * Units.mps.tomph)
  else
    return nil
  end
end

-- Get the current civil (track) braking curve speed limit.
function P:getcivilcurvespeed_mph ()
  local acsesspeed_mps = self._acses:getcurvespeed_mps()
  if acsesspeed_mps then
    return Misc.round(acsesspeed_mps * Units.mps.tomph)
  else
    return nil
  end
end

return P