-- Cab signal and track speed displays for GE Genesis units.
-- We will use the track speed display to display signal speeds above 45 mph.

-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua

local P = {}
GenesisAdu = P

P.aspect = {restrict=1,
            medium=2,
            limited=3,
            clear=4}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit (base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new GenesisAdu context.
function P:new (conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._overspeedflasher = Flash:new{
    scheduler = conf.scheduler,
    off_s = 0.2,
    on_s = 0.3
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Get the currently displayed cab signal aspect.
function P:getaspect ()
  local atcmode = self._atc:getpulsecode()
  if atcmode == Nec.pulsecode.restrict then
    return P.aspect.restrict
  elseif atcmode == Nec.pulsecode.approach then
    return P.aspect.medium
  elseif atcmode == Nec.pulsecode.approachmed then
    return P.aspect.limited
  else
    return P.aspect.clear
  end
end

-- Get the current signal speed limit.
function P:getsignalspeed_mph ()
  local speed_mph = Adu.getsignalspeed_mph(self)
  if speed_mph == 60
      or speed_mph == 80
      or speed_mph == 100
      or speed_mph == 125
      or speed_mph == 150 then
    return nil
  else
    return speed_mph
  end
end

--[[
  Get the current speed limit for the overspeed display, which combines civil
  and signal speed limits if the signal limit cannot be displayed by the ADU
  model.

  In addition, this indicator will flash during the alarm state because it's
  extremely small and difficult to read on the Genesis model.
]]
function P:getoverspeed_mph ()
  local sigspeed_mph = self:getsignalspeed_mph()
  local civspeed_mph = self:getcivilspeed_mph()
  local speed_mph, isalarm
  if sigspeed_mph == nil then
    local truesigspeed_mph = Adu.getsignalspeed_mph(self)
    if truesigspeed_mph < civspeed_mph then
      speed_mph = truesigspeed_mph
      isalarm = self._atc:isalarm()
    else
      speed_mph = civspeed_mph
      isalarm = self._acses:isalarm()
    end
  else
    speed_mph = civspeed_mph
    isalarm = self._acses:isalarm()
  end

  self._overspeedflasher:setflashstate(isalarm)
  if isalarm then
    if self._overspeedflasher:ison() then return speed_mph
    else return nil end
  else
    return speed_mph
  end
end

return P