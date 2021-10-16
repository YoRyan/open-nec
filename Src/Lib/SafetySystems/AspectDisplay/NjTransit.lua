-- An NJT-style integrated speedometer and ADU display.
--
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
NjTransitAdu = P

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new NjTransitAdu context.
function P:new(conf)
  inherit(Adu)
  local o = Adu:new(conf)
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Determine whether or not the current ATC aspect is a clear one.
function P:isclearsignal()
  local atccode = self._atc:getpulsecode()
  return atccode == Nec.pulsecode.clear125 or atccode == Nec.pulsecode.clear150
end

-- Get the combined ATC/ACSES speed limit.
local function getcombinedlimit_mph(self)
  local atc_mph = self._atc:isrunning() and Adu.getsignalspeed_mph(self) or nil
  local acses_mps = self._acses:getcurvespeed_mps()
  local acses_mph =
    (self._acses:isrunning() and acses_mps ~= nil) and acses_mps *
      Units.mps.tomph or nil
  if atc_mph ~= nil and acses_mph ~= nil then
    return math.min(atc_mph, acses_mph)
  else
    return atc_mph ~= nil and atc_mph or acses_mph
  end
end

-- Get the current position of the green speed zone given the current speed.
function P:getgreenzone_mph(speed_mps)
  if not self._acses:isrunning() and self:isclearsignal() then
    return 0
  else
    return getcombinedlimit_mph(self) or 0
  end
end

-- Get the current position of the red speed zone given the current speed.
function P:getredzone_mph(speed_mps)
  if not self._acses:isrunning() and self:isclearsignal() then
    return 0
  else
    local aspeed_mph = math.abs(speed_mps) * Units.mps.tomph
    local limit_mph = getcombinedlimit_mph(self) or 0
    if aspeed_mph > limit_mph then
      return aspeed_mph
    else
      return 0
    end
  end
end

return P
