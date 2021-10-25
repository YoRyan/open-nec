-- This models the behavior of NJ Transit's ASES system, which appears to show
-- braking curves that "count down" to speed restrictions.
--
-- @include SafetySystems/Acses/Acses.lua
-- @include Units.lua
local P = {}
NjtAses = P

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new NjtAses context.
function P:new(conf)
  inherit(Acses)
  local o = Acses:new(conf)
  o._target_mps = nil
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Set useful properties once every update. May be subclassed by other
-- implementations.
function P:_update()
  self._target_mps = self._inforceid ~= nil and
                       self._hazards[self._inforceid].inforce_mps or nil
end

-- Returns the braking curve speed displayed to the operator. Returns nil if ASES
-- is not in service.
function P:getcurvespeed_mph()
  if self:isrunning() and self._inforceid ~= nil then
    local hazard = self._hazards[self._inforceid]
    return (hazard.alert_mps - self._alertlimit_mps) * Units.mps.tomph
  else
    return nil
  end
end

-- Returns the target speed displayed to the operator. Returns nil if ASES is not in
-- service.
function P:gettargetspeed_mph()
  if self:isrunning() and self._inforceid ~= nil then
    local hazard = self._hazards[self._inforceid]
    return hazard.inforce_mps * Units.mps.tomph
  else
    return nil
  end
end

return P
