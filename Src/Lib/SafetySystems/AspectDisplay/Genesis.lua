-- Cab signal and track speed displays for GE Genesis units.
--
-- We will use the track speed display to display signal speeds above 45 mph.
--
-- @include SafetySystems/Acses/AmtrakAcses.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
GenesisAdu = P

P.aspect = {restrict = 1, medium = 2, limited = 3, clear = 4}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new GenesisAdu context.
function P:new(conf)
  inherit(AmtrakTwoSpeedAdu)
  local o = AmtrakTwoSpeedAdu:new(conf)
  o._isamtrak = conf.isamtrak
  o._acses = AmtrakAcses:new{
    cabsignal = o._cabsig,
    getbrakesuppression = conf.getbrakesuppression,
    getacknowledge = conf.getacknowledge,
    consistspeed_mps = (o._isamtrak and 110 or 80) * Units.mph.tomps,
    alertlimit_mps = o._alertlimit_mps,
    penaltylimit_mps = o._penaltylimit_mps,
    alertwarning_s = o._alertwarning_s,
    restrictingspeed_mps = (o._isamtrak and 20 or 15) * Units.mph.tomps
  }
  o._overspeedflasher = Flash:new{off_s = 0.2, on_s = 0.3}
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt)
  AmtrakTwoSpeedAdu.update(self, dt)

  self._overspeedflasher:setflashstate(self:isalarm())
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
  if acsesmode == Acses.mode.approachmed30 or atccode == Nec.pulsecode.approach then
    return P.aspect.medium
  elseif acsesmode == Acses.mode.positivestop or atccode ==
    Nec.pulsecode.restrict then
    return P.aspect.restrict
  elseif atccode == Nec.pulsecode.approachmed then
    return P.aspect.limited
  elseif atccode == Nec.pulsecode.cabspeed60 or atccode ==
    Nec.pulsecode.cabspeed80 or atccode == Nec.pulsecode.clear100 or atccode ==
    Nec.pulsecode.clear125 or atccode == Nec.pulsecode.clear150 then
    return P.aspect.clear
  else
    return nil
  end
end

-- Get the current signal speed limit, which is influenced by both ATC and ACSES.
-- Some speeds cannot be displayed by any Dovetail ADU; these will be displayed
-- using the overspeed limit display.
function P:getsignalspeed_mph()
  local acsesmode = self._acses:getmode()
  local atccode = self._cabsig:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    return 0
  elseif acsesmode == Acses.mode.approachmed30 then
    return 30
  elseif atccode == Nec.pulsecode.restrict then
    return self._isamtrak and 20 or 15
  elseif atccode == Nec.pulsecode.approach then
    return 30
  elseif atccode == Nec.pulsecode.approachmed then
    return 45
  else
    return nil
  end
end

--[[
  Get the current speed limit for the overspeed display, which combines civil
  and signal speed limits if the signal limit cannot be displayed by the ADU
  model.

  In addition, this indicator will flash during the alarm state because it's
  extremely small and difficult to read on the Genesis model.
]]
function P:getoverspeed_mph()
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

  local flashsigspeed = self._sigspeedflasher:getflashstate()
  local acsesspeed_mps = self._acses:getcivilspeed_mps()
  local civilspeed_mph = acsesspeed_mps ~= nil and acsesspeed_mps *
                           Units.mps.tomph or nil
  if self._overspeedflasher:getflashstate() then
    local showoverspeed = self._overspeedflasher:ison()
    if flashsigspeed then
      return showoverspeed and truesigspeed_mph or nil
    else
      return showoverspeed and civilspeed_mph or nil
    end
  elseif flashsigspeed then
    return self._sigspeedflasher:ison() and truesigspeed_mph or nil
  elseif self._showsigspeed:isplaying() then
    return truesigspeed_mph
  else
    return civilspeed_mph
  end
end

return P
