-- This models the behavior of an Amtrak-style ADU, with speed limits that only
-- get revealed if violated.
--
-- @include SafetySystems/Acses/Acses.lua
-- @include Units.lua
local P = {}
AmtrakAcses = P

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new AmtrakAcses context.
function P:new(conf)
  inherit(Acses)
  local o = Acses:new(conf)
  o._revealed_mps = nil
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Set useful properties once every update. May be subclassed by other
-- implementations.
function P:_update()
  -- Compute the speed displayed to the operator.
  local revealedid = Iterator.min(Iterator.ltcomp,
                                  Iterator.map(
                                    function(k, hazard)
      if k[1] == Acses._hazardtype.advancelimit then
        if self._hazardstate[k].violated then
          return k, hazard.alert_mps
        else
          return nil, nil
        end
      else
        return k, hazard.alert_mps
      end
    end, TupleDict.pairs(self._hazards)))
  self._revealed_mps = revealedid ~= nil and
                         self._hazards[revealedid].inforce_mps or nil
end

-- True if ACSES should enter the alarm state. May be subclassed by other
-- implementations.
function P:_shouldalarm()
  if self._inforceid ~= nil then
    local hazard = self._hazards[self._inforceid]
    local isviolated = self._hazardstate[self._inforceid].violated
    local compare_mps =
      isviolated and hazard.inforce_mps + self._alertlimit_mps or
        hazard.alert_mps
    return math.abs(self._getspeed_mps()) > compare_mps
  else
    return false
  end
end

-- Returns the current track speed revealed to the operator. Returns nil if ACSES is
-- not in service.
function P:getrevealedspeed_mph()
  local ok = self:isrunning() and self._revealed_mps ~= nil
  return ok and self._revealed_mps * Units.mps.tomph or nil
end

return P
