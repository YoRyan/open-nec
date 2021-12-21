-- An MTA-style ADU with separate signal and track speed limit displays and
-- "N", "L", "M", "R", and "S" lamps.
--
-- We assume it is not possible to display 60, 80, 100, 125, or 150 mph signal
-- speeds, so we will use the track speed limit display to present them.
--
-- @include SafetySystems/Acses/AmtrakAcses.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
MetroNorthAdu = P

P.aspect = {stop = 0, restrict = 1, medium = 2, limited = 3, normal = 4}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new MetroNorthAdu context.
function P:new(conf)
  inherit(AmtrakTwoSpeedAdu)
  local o = AmtrakTwoSpeedAdu:new(conf)
  o._acses = AmtrakAcses:new{
    cabsignal = o._cabsig,
    getbrakesuppression = conf.getbrakesuppression,
    getacknowledge = conf.getacknowledge,
    getspeed_mps = conf.getspeed_mps,
    gettrackspeed_mps = conf.gettrackspeed_mps,
    getconsistlength_m = conf.getconsistlength_m,
    iterspeedlimits = conf.iterspeedlimits,
    iterrestrictsignals = conf.iterrestrictsignals,
    consistspeed_mps = conf.consistspeed_mps,
    alertlimit_mps = o._alertlimit_mps,
    penaltylimit_mps = o._penaltylimit_mps,
    alertwarning_s = o._alertwarning_s,
    restrictingspeed_mps = 15 * Units.mph.tomps
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- True if the ADU model is capable of displaying the supplied cab signal pulse
-- code.
function P:_canshowpulsecode(pulsecode)
  return pulsecode ~= Nec.pulsecode.cabspeed60 and pulsecode ~=
           Nec.pulsecode.cabspeed80 and pulsecode ~= Nec.pulsecode.clear100 and
           pulsecode ~= Nec.pulsecode.clear125 and pulsecode ~=
           Nec.pulsecode.clear150
end

-- Get the currently displayed cab signal aspect.
function P:getaspect()
  local acsesmode = self._acses:getmode()
  local atccode = self._cabsig:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    return P.aspect.stop
  elseif acsesmode == Acses.mode.approachmed30 or atccode ==
    Nec.pulsecode.approach then
    return P.aspect.medium
  elseif atccode == Nec.pulsecode.restrict then
    return P.aspect.restrict
  elseif atccode == Nec.pulsecode.approachmed then
    return P.aspect.limited
  elseif atccode == Nec.pulsecode.cabspeed60 or atccode ==
    Nec.pulsecode.cabspeed80 or atccode == Nec.pulsecode.clear100 or atccode ==
    Nec.pulsecode.clear125 or atccode == Nec.pulsecode.clear150 then
    return P.aspect.normal
  else
    return nil
  end
end

-- Get the current signal speed limit, which is influenced by both ATC and ACSES.
-- Some speeds cannot be displayed by any Dovetail ADU; these will be displayed
-- using the civil speed limit display.
function P:getsignalspeed_mph()
  local acsesmode = self._acses:getmode()
  local atccode = self._cabsig:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    return 0
  elseif acsesmode == Acses.mode.approachmed30 then
    return 30
  elseif atccode == Nec.pulsecode.restrict then
    return 15
  elseif atccode == Nec.pulsecode.approach then
    return 30
  elseif atccode == Nec.pulsecode.approachmed then
    return 45
  else
    return nil
  end
end

-- Get the current civil speed limit. Some signal speeds cannot be displayed by
-- any Dovetail ADU; they are displayed here.
function P:getcivilspeed_mph()
  local atccode = self._cabsig:getpulsecode()
  local truesigspeed_mph
  if atccode == Nec.pulsecode.cabspeed60 then
    truesigspeed_mph = 60
  elseif atccode == Nec.pulsecode.cabspeed80 then
    truesigspeed_mph = 80
  elseif atccode == Nec.pulsecode.clear100 then
    truesigspeed_mph = 100
  elseif atccode == Nec.pulsecode.clear125 then
    truesigspeed_mph = 125
  elseif atccode == Nec.pulsecode.clear150 then
    truesigspeed_mph = 150
  else
    truesigspeed_mph = nil
  end
  if self._sigspeedflasher:getflashstate() then
    return self._sigspeedflasher:ison() and truesigspeed_mph or nil
  elseif self._showsigspeed:isplaying() then
    return truesigspeed_mph
  else
    return self._acsesspeed_mps ~= nil and self._acsesspeed_mps *
             Units.mps.tomph or nil
  end
end

return P
