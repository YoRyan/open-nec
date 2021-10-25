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

-- Get the combined speed limit--jumps instantaneously to the more restrictive
-- signal or (target) civil speed limit.
local function gettargetspeedlimit_mph(self)
  local atc_mph = self._atc:isrunning() and Adu.getsignalspeed_mph(self) or nil
  local acsescurve_mph = self._acses:getcurvespeed_mph()
  local acsestarget_mph = self._acses:gettargetspeed_mph()
  if atc_mph ~= nil and acsescurve_mph ~= nil then
    return acsescurve_mph < atc_mph and acsestarget_mph or atc_mph
  else
    return atc_mph ~= nil and atc_mph or acsestarget_mph
  end
end

local function readspeed(self)
  while true do
    local targetlimit_mph
    self._sched:select(nil, function()
      targetlimit_mph = gettargetspeedlimit_mph(self)
      return self._targetlimit_mph ~= targetlimit_mph
    end)
    self._sched:yield()
    if not self._atc:isalarm() and not self._acses:isalarm() then
      self:triggeralert()
    end
    self._targetlimit_mph = targetlimit_mph
  end
end

-- Create a new NjTransitAdu context.
function P:new(conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._targetlimit_mph = nil
  setmetatable(o, self)
  self.__index = self
  o._sched:run(readspeed, o)
  return o
end

-- Determine whether or not the current ATC aspect is a clear one.
function P:isclearsignal()
  local atccode = self._atc:getpulsecode()
  return atccode == Nec.pulsecode.clear125 or atccode == Nec.pulsecode.clear150
end

-- Get the combined speed limit--counts down to the more restrictive signal or
-- civil speed limit.
local function getcurvespeedlimit_mph(self)
  local atc_mph = self._atc:isrunning() and Adu.getsignalspeed_mph(self) or nil
  local acses_mph = self._acses:getcurvespeed_mph()
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
    return getcurvespeedlimit_mph(self) or 0
  end
end

-- Get the current position of the red speed zone given the current speed.
function P:getredzone_mph(speed_mps)
  if not self._acses:isrunning() and self:isclearsignal() then
    return 0
  else
    local aspeed_mph = math.abs(speed_mps) * Units.mps.tomph
    local limit_mph = getcurvespeedlimit_mph(self) or 0
    if aspeed_mph > limit_mph then
      return aspeed_mph
    else
      return 0
    end
  end
end

return P
