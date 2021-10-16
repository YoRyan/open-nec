-- A contemporary Amtrak ADU with a combined speed limit display.
--
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
AmtrakCombinedAdu = P

P.aspect = {
  stop = 0,
  restrict = 1,
  approach = 2,
  approachmed30 = 3,
  approachmed45 = 4,
  cabspeed60 = 5,
  cabspeed60off = 6,
  cabspeed80 = 7,
  cabspeed80off = 8,
  clear100 = 9,
  clear125 = 10,
  clear150 = 11
}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new AmtrakCombinedAdu context.
function P:new(conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._csflasher = Flash:new{
    scheduler = conf.scheduler,
    off_os = Nec.cabspeedflash_s,
    on_os = Nec.cabspeedflash_s
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Get the currently displayed cab signal aspect.
function P:getaspect()
  local aspect, flash
  local acsesmode = self._acses:getmode()
  local atccode = self._atc:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    aspect = P.aspect.stop
    flash = false
  elseif acsesmode == Acses.mode.approachmed30 then
    aspect = P.aspect.approachmed30
    flash = false
  elseif atccode == Nec.pulsecode.restrict then
    aspect = P.aspect.restrict
    flash = false
  elseif atccode == Nec.pulsecode.approach then
    aspect = P.aspect.approach
    flash = false
  elseif atccode == Nec.pulsecode.approachmed then
    aspect = P.aspect.approachmed45
    flash = false
  elseif atccode == Nec.pulsecode.cabspeed60 then
    if self._csflasher:ison() then
      aspect = P.aspect.cabspeed60
    else
      aspect = P.aspect.cabspeed60off
    end
    flash = true
  elseif atccode == Nec.pulsecode.cabspeed80 then
    if self._csflasher:ison() then
      aspect = P.aspect.cabspeed80
    else
      aspect = P.aspect.cabspeed80off
    end
    flash = true
  elseif atccode == Nec.pulsecode.clear100 then
    aspect = P.aspect.clear100
    flash = false
  elseif atccode == Nec.pulsecode.clear125 then
    aspect = P.aspect.clear125
    flash = false
  elseif atccode == Nec.pulsecode.clear150 then
    aspect = P.aspect.clear150
    flash = false
  end
  self._csflasher:setflashstate(flash)
  return aspect
end

-- Determine whether the Metro-North aspect indicators should be lit.
function P:getmnrrilluminated()
  return self._cabsig:getterritory() == Nec.territory.mnrr
end

-- Get the current speed limit in force.
function P:getspeedlimit_mph()
  local atc_mph = self:atccutin() and Adu.getsignalspeed_mph(self) or nil
  local acses_mps = self._acses:getrevealedspeed_mps()
  local acses_mph = (self:acsescutin() and acses_mps ~= nil) and acses_mps *
                      Units.mps.tomph or nil
  if atc_mph ~= nil and acses_mph ~= nil then
    return math.min(atc_mph, acses_mph)
  else
    return atc_mph ~= nil and atc_mph or acses_mph
  end
end

-- Get the current time to penalty counter, if any.
function P:gettimetopenalty_s()
  if self._acses:getmode() == Acses.mode.positivestop then
    local ttp_s = self._acses:gettimetopenalty_s()
    if ttp_s ~= nil then
      return math.floor(ttp_s)
    else
      return nil
    end
  else
    return nil
  end
end

-- Get the current state of the ATC indicator light.
function P:getatcindicator()
  local atcspeed_mps = self._atc:getinforcespeed_mps()
  local acsesspeed_mps = self._acses:getrevealedspeed_mps()
  return atcspeed_mps ~= nil and Misc.round(atcspeed_mps * Units.mps.tomph) ~=
           150 and (acsesspeed_mps == nil or atcspeed_mps <= acsesspeed_mps)
end

-- Get the current state of the ACSES indicator light.
function P:getacsesindicator()
  local atcspeed_mps = self._atc:getinforcespeed_mps()
  local acsesspeed_mps = self._acses:getrevealedspeed_mps()
  return acsesspeed_mps ~= nil and
           (atcspeed_mps == nil or Misc.round(atcspeed_mps * Units.mps.tomph) ==
             150 or acsesspeed_mps < atcspeed_mps)
end

-- Get the current state of the ATC system.
function P:atccutin() return self._atc:isrunning() end

-- Get the current state of the ACSES system.
function P:acsescutin() return self._acses:isrunning() end

return P
