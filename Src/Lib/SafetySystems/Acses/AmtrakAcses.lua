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
  o._inforce_mps = nil
  o._civilspeed_mps = nil
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt)
  Acses.update(self, dt)

  -- Compute the in-force speed.
  local inforceid = Iterator.min(Iterator.ltcomp,
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
  self._inforce_mps =
    inforceid ~= nil and self._hazards[inforceid].inforce_mps or nil

  -- Compute the civil (track) speed.
  local civilid = Iterator.min(Iterator.ltcomp, Iterator.map(
                                 function(k, hazard)
      if k[1] == Acses._hazardtype.advancelimit and
        self._hazardstate[k].violated then
        return k, hazard.alert_mps
      elseif k[1] == Acses._hazardtype.currentlimit then
        return k, hazard.alert_mps
      else
        return nil, nil
      end
    end, TupleDict.pairs(self._hazards)))
  self._civilspeed_mps =
    civilid ~= nil and self._hazards[civilid].inforce_mps or nil
end

-- Returns the ACSES-enforced speed revealed to the operator. This includes track
-- speed, positive stops, and Approach Medium 30. Returns nil if ACSES is not in
-- service.
function P:getinforcespeed_mps()
  return self:isrunning() and self._inforce_mps or nil
end

-- Returns the track speed revealed to the operator. Returns nil if ACSES is not
-- in service.
function P:getcivilspeed_mps()
  return self:isrunning() and self._civilspeed_mps or nil
end

return P
