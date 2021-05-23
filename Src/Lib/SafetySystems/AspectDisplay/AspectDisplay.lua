-- Base class for an Aspect Display Unit that interfaces with ATC and ACSES.

--include=RollingStock/Tone.lua

local P = {}
Adu = P

-- From the main coroutine, create a new Adu context. This will add coroutines
-- to the provided scheduler.
function P:new (conf)
  local sched = conf.scheduler
  local o = {
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

local function toroundedmph (v)
  return math.floor(v*Units.mps.tomph + 0.5)
end

local function atcinforce (self)
  local atcspeed_mph = toroundedmph(self._atc:getinforcespeed_mps())
  local acsesspeed_mph = toroundedmph(self._acses:getinforcespeed_mps())
  return atcspeed_mph ~= 150 and atcspeed_mph <= acsesspeed_mph
end

-- Get the current state of the ATC indicator light.
function P:getatcindicator ()
  return self._atc:isrunning()
    and (not self._acses:isrunning() or atcinforce(self))
end

-- Get the current state of the ACSES indicator light.
function P:getacsesindicator ()
  return self._acses:isrunning()
    and (not self._atc:isrunning() or not atcinforce(self))
end

-- Get the current signal speed limit.
function P:getsignalspeed_mph ()
  local acsesmode = self._acses:getmode()
  if acsesmode == Acses.mode.positivestop then
    return 0
  elseif acsesmode == Acses.mode.approachmed30 then
    return 30
  else
    return toroundedmph(self._atc:getinforcespeed_mps())
  end
end

-- Get the current civil (track) speed limit.
function P:getcivilspeed_mph ()
  return toroundedmph(self._acses:getinforcespeed_mps())
end

return P