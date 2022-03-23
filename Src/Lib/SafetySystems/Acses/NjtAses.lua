-- This models the behavior of NJ Transit's ASES system, which appears to show
-- braking curves that "count down" to speed restrictions.
--
-- @include SafetySystems/Acses/Acses.lua
-- @include YoRyan/LibRailWorks/Units.lua
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
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Returns the braking curve speed displayed to the operator. Returns nil if ASES
-- is not in service.
function P:getcurvespeed_mps()
  if self:isrunning() and self._inforceid ~= nil then
    return self._hazards[self._inforceid].alert_mps - self._alertlimit_mps
  else
    return nil
  end
end

-- Returns the target speed displayed to the operator. Returns nil if ASES is not in
-- service.
function P:gettargetspeed_mps()
  if self:isrunning() and self._inforceid ~= nil then
    return self._hazards[self._inforceid].inforce_mps
  else
    return nil
  end
end

return P
