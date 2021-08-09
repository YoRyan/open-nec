-- An NJT-style integrated speedometer and ADU display.

-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua

local P = {}
NjTransitAdu = P

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit (base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new NjTransitAdu context.
function P:new (conf)
  inherit(Adu)
  local o = Adu:new(conf)
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Determine whether or not the current ATC aspect is a clear one.
function P:isclearsignal ()
  local atccode = self._atc:getpulsecode()
  return atccode == Nec.pulsecode.clear125
    or atccode == Nec.pulsecode.clear150
end

-- Get the combined ATC/ACSES speed limit.
function P:getcombinedlimit_mph ()
  local signalspeed_mph = Adu.getsignalspeed_mph(self)
  local civilspeed_mph = self._acses:getcurvespeed_mps(self)*Units.mps.tomph
  local atccutin = self._atc:isrunning()
  local acsescutin = self._acses:isrunning()
  if atccutin and acsescutin then
    return math.min(signalspeed_mph, civilspeed_mph)
  elseif atccutin then
    return signalspeed_mph
  elseif acsescutin then
    return civilspeed_mph
  else
    return nil
  end
end

-- Get the current position of the green speed zone given the current speed.
function P:getgreenzone_mph (speed_mps)
  if not self._acses:isrunning() and self:isclearsignal() then
    return 0
  else
    return self:getcombinedlimit_mph() or 0
  end
end

-- Get the current position of the red speed zone given the current speed.
function P:getredzone_mph (speed_mps)
  if not self._acses:isrunning() and self:isclearsignal() then
    return 0
  else
    local aspeed_mph = math.abs(speed_mps)*Units.mps.tomph
    local limit_mph = self:getcombinedlimit_mph() or 0
    if aspeed_mph > limit_mph then
      return aspeed_mph
    else
      return 0
    end
  end
end

return P