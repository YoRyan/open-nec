-- An MTA-style ADU with separate signal and track speed limit displays and
-- "N", "L", "M", "R", and "S" lamps.
--
-- We assume it is not possible to display 60, 80, 100, 125, or 150 mph signal
-- speeds, so we will use the track speed limit display to present them.
--
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
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
  inherit(Adu)
  local o = Adu:new(conf)
  o._sigspeedflasher = Flash:new{
    scheduler = conf.scheduler,
    off_s = 0.5,
    on_s = 1.5
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Get the currently displayed cab signal aspect, MTA-style.
function P:getaspect()
  local acsesmode = self._acses:getmode()
  local atccode = self._atc:getpulsecode()
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
  end
end

-- Get the current signal speed limit.
function P:getsignalspeed_mph()
  local speed_mph = Adu.getsignalspeed_mph(self)
  if speed_mph == 60 or speed_mph == 80 or speed_mph == 100 or speed_mph == 125 or
    speed_mph == 150 then
    return nil
  else
    return speed_mph
  end
end

-- Get the current civil (track) speed limit, which is combined with the signal
-- speed limit if that limit cannot be displayed by the ADU model.
function P:getcivilspeed_mph()
  local sigspeed_mph = self:getsignalspeed_mph()
  local civspeed_mph = Adu.getcivilspeed_mph(self)
  local speed_mph, flash
  if sigspeed_mph == nil and not self:getacsessound() then
    local truesigspeed_mph = Adu.getsignalspeed_mph(self)
    if self:getatcsound() then
      speed_mph = truesigspeed_mph
      flash = false
    elseif truesigspeed_mph ~= nil and civspeed_mph and truesigspeed_mph <
      civspeed_mph then
      if self._sigspeedflasher:ison() then
        speed_mph = truesigspeed_mph
      else
        speed_mph = nil
      end
      flash = true
    else
      speed_mph = civspeed_mph
      flash = false
    end
  else
    speed_mph = civspeed_mph
    flash = false
  end
  self._sigspeedflasher:setflashstate(flash)
  return speed_mph
end

return P
